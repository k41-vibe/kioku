import SwiftUI
import UIKit

/// A vertical, full-page pager backed by `UICollectionView`.
///
/// The SwiftUI `ScrollView` version fought the reveal drag: both claimed the
/// same vertical pan, `scrollDisabled` flipped while a finger was down and
/// cancelled the gesture in flight, and writing the position back from outside
/// could commit a card on an overshoot. Here the collection view owns paging,
/// `isScrollEnabled` only changes between gestures, and a settled page is
/// reported once instead of being observed through a position binding.
struct ReelPager<Page: View>: UIViewRepresentable {
    /// One entry per slot, in order. Identity decides when a cell is rebuilt.
    let slotIDs: [String]
    /// Slot to show. Applied without animation when it differs from the
    /// slot already on screen.
    let current: Int
    /// Paging is off while the answer is still closed, so the reveal drag is the
    /// only recogniser that can claim the touch.
    let scrollEnabled: Bool
    let page: (Int) -> Page
    /// Called once per settle, with the slot that ended up on screen.
    let onSettle: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero

        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.isPagingEnabled = true
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceVertical = false
        view.contentInsetAdjustmentBehavior = .never
        view.backgroundColor = .clear
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: Coordinator.cellID)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let c = context.coordinator
        c.parent = self

        if c.slotIDs != slotIDs {
            c.slotIDs = slotIDs
            view.reloadData()
            // A new set of slots: place the current one without animating, before
            // the layout can report a settle for the old offset.
            view.layoutIfNeeded()
            c.jump(to: current)
            return
        }

        // Only touch scrolling while no finger owns the view. Flipping it during a
        // drag is what cancelled gestures in the old implementation.
        if view.panGestureRecognizer.state == .possible || view.panGestureRecognizer.state == .failed {
            if view.isScrollEnabled != scrollEnabled { view.isScrollEnabled = scrollEnabled }
        } else {
            c.pendingScrollEnabled = scrollEnabled
        }

        if c.settledSlot != current { c.jump(to: current, animated: true) }
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        static let cellID = "reel"
        var parent: ReelPager
        weak var view: UICollectionView?
        var slotIDs: [String]
        /// The slot the view is resting on; nil until the first layout.
        var settledSlot: Int?
        var pendingScrollEnabled: Bool?

        init(_ parent: ReelPager) {
            self.parent = parent
            self.slotIDs = parent.slotIDs
        }

        func jump(to slot: Int, animated: Bool = false) {
            guard let view, slot >= 0, slot < slotIDs.count, view.bounds.height > 0 else { return }
            let offset = CGPoint(x: 0, y: CGFloat(slot) * view.bounds.height)
            settledSlot = slot
            view.setContentOffset(offset, animated: animated)
        }

        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            slotIDs.count
        }

        func collectionView(_ view: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = view.dequeueReusableCell(withReuseIdentifier: Self.cellID, for: indexPath)
            cell.contentConfiguration = UIHostingConfiguration { parent.page(indexPath.item) }
                .margins(.all, 0)
            cell.backgroundColor = .clear
            return cell
        }

        func collectionView(_ view: UICollectionView, layout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            view.bounds.size
        }

        /// Slot nearest the current offset, clamped to what exists.
        private func slot(for view: UIScrollView) -> Int {
            guard view.bounds.height > 0 else { return 0 }
            let raw = Int((view.contentOffset.y / view.bounds.height).rounded())
            return min(max(raw, 0), max(slotIDs.count - 1, 0))
        }

        private func settle(_ view: UIScrollView) {
            if let pending = pendingScrollEnabled {
                pendingScrollEnabled = nil
                (view as? UICollectionView)?.isScrollEnabled = pending
            }
            let now = slot(for: view)
            guard now != settledSlot else { return }
            settledSlot = now
            parent.onSettle(now)
        }

        func scrollViewDidEndDecelerating(_ view: UIScrollView) { settle(view) }

        func scrollViewDidEndScrollingAnimation(_ view: UIScrollView) { settle(view) }

        func scrollViewDidEndDragging(_ view: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { settle(view) }
        }
    }
}
