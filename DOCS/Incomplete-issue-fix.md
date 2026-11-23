# Arreglo: saltos de línea y líneas en blanco al escribir a mitad del archivo

## Síntomas

En archivos largos, al editar a mitad del contenido, con la barra de desplazamiento vertical bajada (ni arriba ni al final del todo):

1. **Salto de una línea al empezar a escribir.** La vista se desplazaba hacia abajo la altura de una línea: la línea que aparecía arriba pasaba a ser la anterior (por ejemplo, si se veía la 262, pasaba a verse la 261).
2. **Líneas en blanco al pulsar Enter.** Las dos primeras líneas visibles dejaban de verse, aunque el margen seguía mostrando su número de línea. Volvían a aparecer al deshacer. Pasaba más cuanto más abajo en el archivo.

Escribiendo al final del archivo, o con la barra arriba del todo, todo funcionaba bien. Ambos fallos eran frecuentes pero intermitentes. El repositorio original (dqhieu/Silica, versión 0.8.0) tiene el mismo comportamiento.

## Causa

El editor usa **TextKit 2** (`EditorTextView(usingTextLayoutManager: true)`), que solo maqueta (hace el *layout* de) las líneas que están en pantalla. De ahí salen tres problemas:

1. **Alturas estimadas por encima de la vista.** Al saltar a mitad del archivo con la barra de desplazamiento, las líneas que quedan por encima no se miden: se les asigna una altura estimada. La maquetación que sigue a una edición sustituye esas estimaciones por alturas reales, y esa corrección mueve el texto visible.
2. **Recoloreado de todo el archivo.** `SyntaxHighlighter.apply(_:)` volvía a aplicar `.foregroundColor` a **todo** el documento unos 120 ms después de cada edición. Con TextKit 2, cambiar atributos invalida la maquetación del rango afectado, así que se descartaba la de todas las líneas, incluidas las estimadas, y se provocaba la misma corrección.
3. **Zona de maquetación desincronizada tras Enter.** Al pulsar Enter, AppKit llama a `scrollRangeToVisible` para mantener el cursor a la vista. TextKit 2 puede mover entonces su zona de maquetación (*viewport*) hacia el cursor sin desplazar la vista, y nadie la vuelve a maquetar. Las líneas que quedan fuera de esa zona no se dibujan, aunque el margen de números, que consulta directamente al *layout manager*, las sigue numerando. El código ya tenía una corrección para este fallo con la barra de búsqueda, pero el commit `efa972e` (PR #19) la limitó a la búsqueda para no maquetar de nuevo en cada pulsación.

### Intentos descartados

La primera versión dejaba que TextKit 2 moviera el texto y luego devolvía la vista a su sitio desde `layout()` y `viewWillDraw()`. Corregía el salto, pero desplazar la vista en mitad del ciclo de maquetación y dibujado dejaba sin dibujar las líneas que el desplazamiento descubría. Se sustituyó por el enfoque actual: evitar que el texto se mueva, en lugar de corregirlo después.

## Cambios

### 1. `Silica/Editor/Syntax/SyntaxHighlighter.swift`: recolorear solo lo que cambia

`apply(_:)` calcula el color que debe tener cada unidad UTF-16 (los tokens posteriores prevalecen, como antes), recorre las tramas de color resultantes y solo aplica `.foregroundColor` donde el color actual es distinto. Normalmente eso se limita al token que se está escribiendo, así que TextKit 2 ya no vuelve a maquetar todo el documento. También es menos trabajo por pulsación.

```swift
private func apply(_ tokens: [SyntaxToken]) {
    guard let textView, let storage = textView.textStorage else { return }
    // Recoloring under in-progress IME composition would disturb the marked text.
    if textView.hasMarkedText() {
        schedule(after: Self.editDelay)
        return
    }

    let theme = EditorSettings.shared.syntaxTheme
    let length = storage.length
    guard length > 0 else { return }

    // The color each UTF-16 unit should have, as an index into `palette`; later
    // tokens win, as when they were applied one after another.
    var palette: [NSColor] = [SyntaxTheme.plain]
    var paletteIndex: [ObjectIdentifier: Int] = [ObjectIdentifier(SyntaxTheme.plain): 0]
    var wanted = [Int32](repeating: 0, count: length)
    wanted.withUnsafeMutableBufferPointer { wanted in
        for token in tokens where token.range.length > 0 && NSMaxRange(token.range) <= length {
            let color = theme.color(for: token.kind)
            let index: Int
            if let known = paletteIndex[ObjectIdentifier(color)] {
                index = known
            } else {
                palette.append(color)
                index = palette.count - 1
                paletteIndex[ObjectIdentifier(color)] = index
            }
            wanted[token.range.location..<NSMaxRange(token.range)].update(repeating: Int32(index))
        }
    }

    // Only runs whose color actually changes are touched. Recoloring the whole file
    // made TextKit 2 throw away the layout of every line, including the estimated
    // ones above the view, which could slide the text while typing.
    var changes: [(NSRange, NSColor)] = []
    var start = 0
    while start < length {
        let index = wanted[start]
        var end = start + 1
        while end < length, wanted[end] == index { end += 1 }
        let run = NSRange(location: start, length: end - start)
        var effective = NSRange(location: 0, length: 0)
        let current = storage.attribute(.foregroundColor, at: start, longestEffectiveRange: &effective, in: run) as? NSColor
        let color = palette[Int(index)]
        if current != color || NSMaxRange(effective) < end {
            changes.append((run, color))
        }
        start = end
    }
    guard !changes.isEmpty else { return }

    storage.beginEditing()
    for (range, color) in changes {
        storage.addAttribute(.foregroundColor, value: color, range: range)
    }
    storage.endEditing()
}
```

### 2. `Silica/Editor/EditorTextView.swift`

#### Medir las líneas de arriba antes de cada edición

Antes de cada edición (`shouldChangeText(in:replacementString:)` y `shouldChangeText(inRanges:replacementStrings:)`), `measureLinesAboveView()` maqueta el texto desde el principio del documento hasta el final de la vista con `ensureLayout(for:)`. Si eso mueve la línea superior, desplaza la vista para dejarla donde estaba. Se hace mientras se procesa la tecla, fuera de la maquetación y el dibujado, así que el desplazamiento se dibuja bien. Después la edición ya no encuentra estimaciones que corregir.

Solo trabaja tras un desplazamiento, un cambio de tamaño o un cambio de fuente. Mientras se escribe sin desplazarse no hace nada. La primera tecla tras saltar a mitad de un archivo muy grande puede tardar un instante.

```swift
// MARK: Holding the view still across edits

/// Where the view was the last time the lines above it were measured.
private struct MeasuredView: Equatable {
    var top: CGFloat
    var width: CGFloat
    var fontSize: CGFloat
}

private var measuredView: MeasuredView?

private var currentMeasuredView: MeasuredView {
    MeasuredView(top: visibleRect.minY, width: bounds.width, fontSize: font?.pointSize ?? 0)
}

/// TextKit 2 only lays out the lines on screen. After a jump with the scroller, the
/// lines above the view keep estimated heights, and the layout pass that follows an
/// edit replaces them with real ones, sliding the text by a line or so. This measures
/// those lines before the edit, while handling the key press (not in the middle of
/// layout or drawing, where scrolling leaves lines blank), and scrolls so the top
/// line stays put; the edit then has no estimates above it left to correct.
/// It's skipped until the view scrolls, resizes or changes font.
func measureLinesAboveView() {
    guard let layoutManager = textLayoutManager,
          let contentManager = layoutManager.textContentManager else { return }
    guard currentMeasuredView != measuredView else { return }
    let visible = visibleRect
    // At the very top there's nothing above to measure.
    guard visible.minY > 0 else {
        measuredView = currentMeasuredView
        return
    }

    let origin = textContainerOrigin
    let documentStart = layoutManager.documentRange.location
    // A point into the view, so rounding at a line boundary doesn't pick the line above.
    let topPoint = CGPoint(x: 0, y: max(0, visible.minY - origin.y + 1))
    guard let top = layoutManager.textLayoutFragment(for: topPoint) else { return }
    let topOffset = contentManager.offset(from: documentStart, to: top.rangeInElement.location)
    let delta = visible.minY - (top.layoutFragmentFrame.minY + origin.y)

    // Through the bottom of the view, so the lines on screen land where they really go.
    let bottomPoint = CGPoint(x: 0, y: max(0, visible.maxY - origin.y))
    let end = layoutManager.textLayoutFragment(for: bottomPoint)?.rangeInElement.endLocation
        ?? top.rangeInElement.endLocation
    guard let range = NSTextRange(location: documentStart, end: end) else { return }
    layoutManager.ensureLayout(for: range)

    guard let location = contentManager.location(documentStart, offsetBy: topOffset),
          let measured = layoutManager.textLayoutFragment(for: location) else { return }
    let y = measured.layoutFragmentFrame.minY + origin.y + delta
    if abs(y - visible.minY) >= 0.5 {
        // The view's height follows the corrected line heights.
        sizeToFit()
        scroll(NSPoint(x: visible.minX, y: max(0, y)))
    }
    measuredView = currentMeasuredView
}

override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
    let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    if allowed { measureLinesAboveView() }
    return allowed
}

override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
    let allowed = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    if allowed { measureLinesAboveView() }
    return allowed
}
```

#### Rehacer la zona de maquetación cuando se desincroniza

Después de `scrollRangeToVisible`, fuera de la barra de búsqueda, se comprueba si la zona de maquetación empieza por debajo de la línea que está arriba de la vista. Solo en ese caso se llama a `layoutViewport()`, así que al escribir normalmente no se fuerza una maquetación extra, como buscaba el PR #19.

La misma comprobación se repite después de la maquetación que sigue a cada edición, porque TextKit 2 también puede desincronizar la zona en ese momento. Se programa desde `didChangeText()` y desde `layout()`, pero se ejecuta en la siguiente vuelta del bucle de eventos, nunca en mitad de la maquetación o el dibujado.

```swift
override func didChangeText() {
    super.didChangeText()
    // Guides follow the text, so any edit can move them.
    setNeedsDisplay(visibleRect)
    checkViewportAfterLayout()
}

override func layout() {
    super.layout()
    if isViewportCheckPending {
        isViewportCheckPending = false
        scheduleViewportCheck()
    }
}

/// TextKit 2 can move its viewport toward `range` without scrolling the view, and
/// nothing lays the viewport out again. With Find, matches go unhighlighted; after
/// Return, the lines at the top of the view aren't drawn, though the gutter still
/// numbers them. While editing, the viewport is only laid out again when it has
/// fallen off the top line on screen, not for every caret scroll.
override func scrollRangeToVisible(_ range: NSRange) {
    super.scrollRangeToVisible(range)
    if enclosingScrollView?.isFindBarVisible == true, window?.firstResponder !== self {
        textLayoutManager?.textViewportLayoutController.layoutViewport()
    } else if viewportMissesTopLine() {
        textLayoutManager?.textViewportLayoutController.layoutViewport()
    }
}

// MARK: Viewport after edits

private var isViewportCheckPending = false
private var isViewportCheckScheduled = false

/// The layout pass that follows an edit can also leave the viewport below the top
/// line, after `scrollRangeToVisible` has already checked it. Checks again once
/// that pass is over: from `layout()`, but on the next turn of the run loop rather
/// than in the middle of layout and drawing.
private func checkViewportAfterLayout() {
    isViewportCheckPending = true
    // In case no layout pass follows the edit.
    scheduleViewportCheck()
}

private func scheduleViewportCheck() {
    guard !isViewportCheckScheduled else { return }
    isViewportCheckScheduled = true
    DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.isViewportCheckScheduled = false
        if self.viewportMissesTopLine() {
            self.textLayoutManager?.textViewportLayoutController.layoutViewport()
            self.setNeedsDisplay(self.visibleRect)
        }
    }
}

/// True when the viewport starts below the line at the top of the view.
private func viewportMissesTopLine() -> Bool {
    guard let layoutManager = textLayoutManager,
          let viewport = layoutManager.textViewportLayoutController.viewportRange else { return false }
    let visible = visibleRect
    // A point into the view, so rounding at a line boundary doesn't pick the line above.
    let point = CGPoint(x: 0, y: max(0, visible.minY - textContainerOrigin.y + 1))
    guard let top = layoutManager.textLayoutFragment(for: point) else { return false }
    return viewport.location.compare(top.rangeInElement.location) == .orderedDescending
}
```

## Resultado

- El salto de una línea al escribir ha desaparecido.
- Las líneas en blanco al pulsar Enter son mucho menos frecuentes. Antes de la segunda comprobación, en pruebas repetidas solo aparecían de forma muy ocasional al pulsar Enter muy abajo en archivos largos. Esa segunda comprobación está pendiente de probar.

## Pruebas manuales

1. Abrir un archivo largo y arrastrar la barra de desplazamiento hasta la mitad.
2. Hacer clic en una línea y escribir: la línea superior no se mueve.
3. Pulsar Enter muchas veces en distintas líneas, a mitad y cerca del final de un archivo largo: las primeras líneas siguen visibles.
4. Pulsar Enter en la última línea visible: la vista baja para mostrar el cursor.
5. Abrir la barra de búsqueda: las coincidencias se resaltan como antes.
6. Deshacer y rehacer: funcionan como antes.

## Posible mejora futura

Mover el coloreado de sintaxis a los *rendering attributes* de TextKit 2 (`NSTextLayoutManager.setRenderingAttributes`), que no afectan a la maquetación. Es un cambio mayor, porque el minimapa lee los colores directamente del almacenamiento de texto.
