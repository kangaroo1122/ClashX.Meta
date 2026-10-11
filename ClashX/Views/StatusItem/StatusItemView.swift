//
//  StatusItemView.swift
//  ClashX
//
//  Created by CYC on 2018/6/23.
//  Copyright © 2018年 yichengchen. All rights reserved.
//
//  Thanks https://github.com/exelban/stats

import AppKit
import Foundation

@MainActor
final class StatusItemView: NSView, StatusItemViewProtocol {
    var statusItem: NSStatusItem?

    private var upText: String = SpeedUtils.getSpeedString(for: 0)
    private var downText: String = SpeedUtils.getSpeedString(for: 0)
    private var showSpeed: Bool = true
    private var enableProxy: Bool = false

    private var textHeight: CGFloat?

    private static let horizontalPadding: CGFloat = 3
    private static let iconSize: CGFloat = 16
    private static let iconTextSpacing: CGFloat = 2
    private static let itemHeight: CGFloat = 22
    private let textFont = StatusItemTool.font
    private lazy var iconImage: NSImage = StatusItemTool.menuImage

    private let fixedTextWidth: CGFloat
    private let statusItemLengthWithSpeed: CGFloat
    private let statusItemLengthWithoutSpeed: CGFloat

    private static func measuredFixedTextWidth() -> CGFloat {
        ceil(("1000.0MB/s" as NSString).size(withAttributes: [.font: StatusItemTool.font]).width)
    }

    static func create() async -> StatusItemView {
        let view = StatusItemView(frame: .zero)
        let length = view.statusItemLengthWithSpeed
        view.frame = NSRect(x: 0, y: 0, width: length, height: Self.itemHeight)
        let statusItem = NSStatusBar.system.statusItem(withLength: length)
        view.statusItem = statusItem

        guard let button = statusItem.button else {
            Logger.log("button = nil")
            await ConfigFileManager.shared.openConfigFolder()
            return view
        }

        button.subviews.filter { $0 is StatusItemView }.forEach { $0.removeFromSuperview() }
        button.addSubview(view)
        button.image = NSImage()
        view.updateViewStatus(enableProxy: false)
        return view
    }

    // macOS 26: suppress the WindowServer "Invalid window" log spam.
    // Status bar windows can never be tiled, so override the tiling gate to skip the sync.
    // Source: https://github.com/exelban/stats (helpers.swift, #3395)
    static func suppressStatusBarTilingConstraintUpdates() {
        guard #available(macOS 26.0, *) else { return }
        let selector = NSSelectorFromString("_needsTilingConstraintUpdate")
        guard let cls = NSClassFromString("NSStatusBarWindow"),
              let method = class_getInstanceMethod(cls, selector) else { return }
        let block: @convention(block) (AnyObject) -> Bool = { _ in false }
        class_addMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }

    override init(frame frameRect: NSRect) {
        let fixedTextWidth = Self.measuredFixedTextWidth()
        self.fixedTextWidth = fixedTextWidth
        self.statusItemLengthWithSpeed = Self.horizontalPadding * 2 + Self.iconSize + Self.iconTextSpacing + fixedTextWidth
        self.statusItemLengthWithoutSpeed = Self.horizontalPadding * 2 + Self.iconSize
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: frame.width, height: Self.itemHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let sharedColor = enableProxy ? NSColor.labelColor : NSColor.labelColor.withSystemEffect(.disabled)

        let iconRect = CGRect(
            x: Self.horizontalPadding,
            y: floor((bounds.height - Self.iconSize) * 0.5),
            width: Self.iconSize,
            height: Self.iconSize
        )
        NSGraphicsContext.saveGraphicsState()
        sharedColor.set()
        iconRect.fill()
        iconImage.draw(in: iconRect, from: .zero, operation: .destinationIn, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard showSpeed else { return }

        let style = NSMutableParagraphStyle()
        // Keep short rates close to the icon without resizing the menu bar item.
        style.alignment = .left

        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: sharedColor,
            .paragraphStyle: style
        ]

        let upAttributed = NSAttributedString(string: upText, attributes: attributes)
        let downAttributed = NSAttributedString(string: downText, attributes: attributes)
        let textWidth = fixedTextWidth
        let textHeight = measuredTextHeight
        let textX = iconRect.maxX + Self.iconTextSpacing
        let upRect = CGRect(x: textX, y: 12, width: textWidth, height: textHeight)
        let downRect = CGRect(x: textX, y: 2, width: textWidth, height: textHeight)

        upAttributed.draw(with: upRect)
        downAttributed.draw(with: downRect)
    }

    private var measuredTextHeight: CGFloat {
        if let textHeight {
            return textHeight
        }
        let height = (upText as NSString).size(withAttributes: [.font: textFont]).height
        textHeight = height
        return height
    }

    func updateSize(_ statusItem: NSStatusItem?, showSpeed: Bool) {
        let width = showSpeed ? statusItemLengthWithSpeed : statusItemLengthWithoutSpeed
        let newLength = max(width, 1)
        guard frame.width != width || statusItem?.length != newLength else { return }
        frame = NSRect(x: 0, y: 0, width: width, height: Self.itemHeight)
        statusItem?.length = newLength
        display()
    }

    func updateViewStatus(enableProxy: Bool) {
        self.enableProxy = enableProxy
        display()
    }

    func updateSpeedLabel(up: Int, down: Int) {
        guard showSpeed else { return }
        let upText = SpeedUtils.getSpeedString(for: up)
        let downText = SpeedUtils.getSpeedString(for: down)
        guard upText != self.upText || downText != self.downText else { return }
        self.upText = upText
        self.downText = downText
        display()
    }

    func showSpeedContainer(show: Bool) {
        showSpeed = show
        display()
    }
}
