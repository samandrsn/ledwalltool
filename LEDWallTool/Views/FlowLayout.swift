import SwiftUI

/// Lays controls out left to right and wraps onto a new line when the row is full,
/// so view toolbars stay readable in narrow windows instead of squashing.
struct FlowLayout: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 6

    private struct Line { var items: [(Int, CGSize)] = []; var height: CGFloat = 0 }

    private func lines(_ maxW: CGFloat, _ subviews: Subviews) -> [Line] {
        var out = [Line()], x: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            var sz = s.sizeThatFits(.unspecified)
            if sz.width > maxW { sz = s.sizeThatFits(ProposedViewSize(width: maxW, height: nil)) }
            if x > 0 && x + sz.width > maxW { out.append(Line()); x = 0 }
            out[out.count - 1].items.append((i, sz))
            out[out.count - 1].height = max(out[out.count - 1].height, sz.height)
            x += sz.width + spacing
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // SwiftUI also asks for ideal (nil) and minimum (~0) sizes. Answer those with a single
        // line and no width demand, so the bar never forces the window wider or taller; it only
        // wraps to the width it is actually given.
        guard let maxW = proposal.width, maxW.isFinite, maxW > 120 else {
            let h = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            return CGSize(width: 0, height: h)
        }
        let ls = lines(maxW, subviews)
        let height = ls.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, ls.count - 1))
        return CGSize(width: maxW, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for l in lines(bounds.width, subviews) {
            var x = bounds.minX
            for (i, sz) in l.items {
                subviews[i].place(at: CGPoint(x: x, y: y + (l.height - sz.height) / 2), proposal: ProposedViewSize(sz))
                x += sz.width + spacing
            }
            y += l.height + lineSpacing
        }
    }
}

/// A view-level toolbar strip under the window toolbar.
struct ViewBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        FlowLayout { content }
            .controlSize(.regular)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
}
