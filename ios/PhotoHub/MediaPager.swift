import SwiftUI
import UIKit

/// UIKit owns the interactive transition, including velocity, cancellation and edge resistance.
struct NativeMediaPager<Content: View>: UIViewControllerRepresentable {
    let count: Int
    @Binding var selection: Int
    var vertical = false
    var enabled = true
    @ViewBuilder var content: (Int, Bool) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: vertical ? .vertical : .horizontal)
        controller.view.backgroundColor = .black
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.controller = controller
        if let page = context.coordinator.page(selection) { controller.setViewControllers([page], direction: .forward, animated: false) }
        return controller
    }
    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Replacing a hosting root while its child is pinching can replace the
        // zoom view mid-gesture. Keep loaded views stable until interaction ends.
        if enabled && !coordinator.transitioning {
            for (index, page) in coordinator.pages where (0..<count).contains(index) { page.rootView = content(index, index == coordinator.activeIndex) }
        }
        // Disable only the ancestor's paging pan. Changing its scroll-enabled
        // state or data source during a pinch can interrupt the child zoom view.
        controller.view.subviews.compactMap { $0 as? UIScrollView }.forEach {
            $0.panGestureRecognizer.maximumNumberOfTouches = 1
            $0.panGestureRecognizer.isEnabled = enabled && count > 1
        }
        coordinator.reconcile()
    }
    static func dismantleUIViewController(_ controller: UIPageViewController, coordinator: Coordinator) {
        controller.delegate = nil; controller.dataSource = nil
        coordinator.clear()
    }
    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: NativeMediaPager
        weak var controller: UIPageViewController?
        private(set) var pages: [Int: UIHostingController<Content>] = [:]
        private(set) var transitioning = false
        private(set) var activeIndex: Int
        init(_ parent: NativeMediaPager) { self.parent = parent; activeIndex = parent.selection }
        func activate(_ index: Int) {
            activeIndex = index
            for (position, page) in pages where (0..<parent.count).contains(position) { page.rootView = parent.content(position, position == index) }
        }
        func clear() { pages.removeAll(); controller = nil }
        func page(_ index: Int) -> UIHostingController<Content>? {
            guard (0..<parent.count).contains(index) else { return nil }
            if let existing = pages[index] { return existing }
            let page = UIHostingController(rootView: parent.content(index, index == activeIndex))
            page.view.backgroundColor = .black
            pages[index] = page
            return page
        }
        func index(of page: UIViewController) -> Int? { pages.first { $0.value === page }?.key }
        func trim(around index: Int) { pages = pages.filter { abs($0.key - index) <= 1 } }
        func reconcile() {
            guard !transitioning, let controller, let visible = controller.viewControllers?.first,
                  let current = index(of: visible), current != parent.selection, let target = page(parent.selection) else { return }
            transitioning = true
            controller.setViewControllers([target], direction: parent.selection > current ? .forward : .reverse,
                                          animated: !parent.reduceMotion) { [weak self] _ in
                guard let self else { return }
                self.transitioning = false
                if let visible = controller.viewControllers?.first, let current = self.index(of: visible) { self.activate(current); self.trim(around: current) }
                self.reconcile() // Coalesce button taps without overlapping animations.
            }
        }
        func pageViewController(_ controller: UIPageViewController, viewControllerBefore page: UIViewController) -> UIViewController? {
            guard let index = index(of: page) else { return nil }; return self.page(index - 1)
        }
        func pageViewController(_ controller: UIPageViewController, viewControllerAfter page: UIViewController) -> UIViewController? {
            guard let index = index(of: page) else { return nil }; return self.page(index + 1)
        }
        func pageViewController(_ controller: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) { transitioning = true }
        func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            guard let page = controller.viewControllers?.first, let current = index(of: page) else { return }
            if completed { parent.selection = current; activate(current) }
            trim(around: current)
            reconcile()
        }
    }
}

struct PhoneZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onTap: () -> Void
    var onZoomChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PhoneImageScrollView {
        let view = PhoneImageScrollView()
        view.delegate = context.coordinator
        view.minimumZoomScale = 1
        view.maximumZoomScale = 6
        view.bouncesZoom = true
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.accessibilityIdentifier = "media-image-zoom"
        view.imageView.image = image
        view.imageView.contentMode = .scaleAspectFit
        view.addSubview(view.imageView)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        view.addGestureRecognizer(tap)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)
        view.pinchGestureRecognizer?.addTarget(context.coordinator, action: #selector(Coordinator.pinchFinished(_:)))
        return view
    }
    func updateUIView(_ view: PhoneImageScrollView, context: Context) {
        context.coordinator.parent = self
        if view.imageView.image !== image {
            view.setZoomScale(1, animated: false)
            view.imageView.image = image
            view.fittedSize = .zero
            view.setNeedsLayout()
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: PhoneZoomableImage
        init(_ parent: PhoneZoomableImage) { self.parent = parent }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? PhoneImageScrollView)?.imageView
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? PhoneImageScrollView)?.centerImage()
            let pinch = scrollView.pinchGestureRecognizer
            parent.onZoomChanged(!Self.allowsPaging(zoomScale: scrollView.zoomScale, pinchTouches: pinch?.numberOfTouches ?? 0, pinchState: pinch?.state ?? .possible))
        }
        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { parent.onZoomChanged(true) }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { finishZoom(scrollView) }
        private func finishZoom(_ scrollView: UIScrollView) {
            // Treat tiny residual scale as fitted, rather than trapping the next swipe.
            if scrollView.zoomScale <= scrollView.minimumZoomScale * 1.02 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
                parent.onZoomChanged(false)
            } else { parent.onZoomChanged(true) }
        }
        @objc func pinchFinished(_ gesture: UIPinchGestureRecognizer) {
            guard gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed,
                  let scroll = gesture.view as? UIScrollView else { return }
            // Run after UIKit's own pinch targets and final bounce update.
            DispatchQueue.main.async { [weak self, weak scroll] in
                guard let self, let scroll else { return }; self.finishZoom(scroll)
            }
        }
        static func allowsPaging(zoomScale: CGFloat, pinchTouches: Int, pinchState: UIGestureRecognizer.State) -> Bool {
            // A possible pinch also tracks a single finger; that is still a paging gesture.
            // Keep blocking an active pinch when one finger lifts before the other.
            zoomScale <= 1.001 && pinchTouches < 2 && pinchState != .began && pinchState != .changed
        }
        @objc func tap() { parent.onTap() }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? PhoneImageScrollView else { return }
            if scroll.zoomScale > 1.001 { scroll.setZoomScale(1, animated: true) }
            else {
                let point = gesture.location(in: scroll.imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}

final class PhoneImageScrollView: UIScrollView {
    let imageView = UIImageView()
    var fittedSize = CGSize.zero
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer { return zoomScale > 1.001 }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedSize, bounds.width > 0, bounds.height > 0,
           let image = imageView.image, image.size.width > 0, image.size.height > 0 {
            fittedSize = bounds.size
            setZoomScale(1, animated: false)
            let ratio = min(bounds.width / image.size.width, bounds.height / image.size.height)
            imageView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * ratio, height: image.size.height * ratio))
            contentSize = imageView.frame.size
        }
        centerImage()
    }
    func centerImage() {
        accessibilityValue = String(format: "%.2f倍", zoomScale)
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - imageView.frame.height) / 2), left: max(0, (bounds.width - imageView.frame.width) / 2), bottom: 0, right: 0)
    }
}

