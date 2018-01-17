// Copyright (c) 2018 Token Browser, Inc
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

import SweetUIKit
import TinyConstraints
import UIKit

protocol DisappearingBackgroundNavBarDelegate: class {
    
    func didTapLeftButton(in navBar: DisappearingBackgroundNavBar)
    func didTapRightButton(in navBar: DisappearingBackgroundNavBar)
}

/// A view to allow a fake nav bar that can appear and disappear as the user scrolls, but allowing its buttons to stay in place.
final class DisappearingBackgroundNavBar: UIView {
    
    private let animationSpeed = 0.25
    private let interItemSpacing: CGFloat = 8
    
    weak var delegate: DisappearingBackgroundNavBarDelegate?
    
    static let defaultHeight: CGFloat = 64
    
    private lazy var leftButton: UIButton = {
        let button = UIButton(withAutoLayout: true)
        button.tintColor = Theme.tintColor
        button.addTarget(self, action: #selector(leftButtonTapped), for: .touchUpInside)

        return button
    }()
    
    private lazy var rightButton: UIButton = {
        let button = UIButton(withAutoLayout: true)
        button.tintColor = Theme.tintColor
        button.addTarget(self, action: #selector(rightButtonTapped), for: .touchUpInside)
        
        return button
    }()
    
    private lazy var bottomBorder: UIView = {
        let view = UIView(withAutoLayout: true)
        view.backgroundColor = Theme.borderColor
        
        return view
    }()
    
    private lazy var titleLabel: UILabel = {
        let label = UILabel(withAutoLayout: false)
        label.font = Theme.preferredSemibold()
        label.textAlignment = .center
        
        return label
    }()
    
    private lazy var backgroundView: UIView = {
        let view = UIView(withAutoLayout: true)
        view.backgroundColor = .white
        
        let bottomBorder = BorderView()
        view.addSubview(bottomBorder)
        bottomBorder.edgesToSuperview(excluding: .top)
        bottomBorder.addHeightConstraint()
        
        return view
    }()
    
    // MARK: - Initialization
    
    convenience init(delegate: DisappearingBackgroundNavBarDelegate?) {
        self.init(frame: .zero)
        self.delegate = delegate
        
        setupBackground()
        setupLeftButton()
        setupRightButton()
        setupTitleLabel(leftButton: leftButton, rightButton: rightButton)
        setupBottomBorder()
    }
    
    private func setupBackground() {
        addSubview(backgroundView)
        
        backgroundView.edgesToSuperview()
        backgroundView.alpha = 0
    }
    
    private func setupLeftButton() {
        addSubview(leftButton)
        
        leftButton.leftToSuperview(offset: interItemSpacing)
        leftButton.centerYToSuperview(offset: 10)
        leftButton.setContentHuggingPriority(.required, for: .horizontal)
        leftButton.width(min: .defaultButtonHeight)
        leftButton.height(min: .defaultButtonHeight)
        
        leftButton.isHidden = true
    }
    
    private func setupRightButton() {
        addSubview(rightButton)
        
        rightButton.rightToSuperview(offset: interItemSpacing)
        rightButton.centerYToSuperview(offset: 10)
        rightButton.setContentHuggingPriority(.required, for: .horizontal)
        rightButton.width(min: .defaultButtonHeight)
        rightButton.height(min: .defaultButtonHeight)
        
        rightButton.isHidden = true
    }
    
    private func setupTitleLabel(leftButton: UIButton, rightButton: UIButton) {
        assert(leftButton.superview != nil)
        assert(rightButton.superview != nil)
        
        addSubview(titleLabel)
        
        titleLabel.centerYToSuperview(offset: 10)
        titleLabel.leftToRight(of: leftButton, offset: interItemSpacing)
        titleLabel.rightToLeft(of: rightButton, offset: interItemSpacing)
        
        titleLabel.alpha = 0
    }
    
    private func setupBottomBorder() {
        addSubview(bottomBorder)
        
        bottomBorder.edgesToSuperview(excluding: .top)
        bottomBorder.height(CGFloat.lineHeight)
        
        bottomBorder.alpha = 0
    }
    
    // MARK: - Button Images
    
    /// Sets up the left button to appear to be a back button.
    func setupLeftAsBackButton() {
        setLeftButtonImage(#imageLiteral(resourceName: "navigation_back"), accessibilityLabel: Localized("accessibility_back"))
    }
    
    /// Takes an image, turns it into an always-template image, then sets it to the left button and un-hides the left button.
    ///
    /// - Parameters:
    ///   - image: The image to set on the left button as a template image.
    ///   - accessibilityLabel: The accessibility label which should be read to voice over users describing the left button.
    func setLeftButtonImage(_ image: UIImage, accessibilityLabel: String) {
        let templateImage = image.withRenderingMode(.alwaysTemplate)
        leftButton.setImage(templateImage, for: .normal)
        leftButton.accessibilityLabel = accessibilityLabel
        leftButton.isHidden = false
        
        let imageWidth = image.size.width
        let differenceFromDefault = .defaultButtonHeight - imageWidth
        if differenceFromDefault > 0 {
            leftButton.imageEdgeInsets = UIEdgeInsets(top: 0,
                                                      left: -differenceFromDefault,
                                                      bottom: 0,
                                                      right: 0)
        }
    }
    
    /// Takes an image, turns it into an always-template image, then sets it to the right button and un-hides the right button.
    ///
    /// - Parameters:
    ///   - image: The image to set on the right button as a template image.
    ///   - accessibilityLabel: The accessibility label which should be read to voice over users describing the right button.
    func setRightButtonImage(_ image: UIImage, accessibilityLabel: String) {
        let templateImage = image.withRenderingMode(.alwaysTemplate)
        rightButton.setImage(templateImage, for: .normal)
        rightButton.isHidden = false
        rightButton.accessibilityLabel = accessibilityLabel
        
        let imageWidth = image.size.width
        let differenceFromDefault = .defaultButtonHeight - imageWidth
        if differenceFromDefault > 0 {
            rightButton.imageEdgeInsets = UIEdgeInsets(top: 0,
                                                       left: 0,
                                                       bottom: 0,
                                                       right: -differenceFromDefault)
        }
    }
    
    /// Sets a string as the title. Does *not* automatically show it.
    ///
    /// - Parameter text: The text to set as the title.
    func setTitle(_ text: String) {
        titleLabel.text = text
    }
    
    // MARK: - Show/Hide
    
    func showBottomBorder(_ shouldShow: Bool, animated: Bool = true) {
        showView(bottomBorder, shouldShow: shouldShow, animated: animated)
    }
    
    func showTitleLabel(_ shouldShow: Bool, animated: Bool = true) {
        showView(titleLabel, shouldShow: shouldShow, animated: animated)
    }
    
    func showBackground(_ shouldShow: Bool, animated: Bool = true) {
        showView(backgroundView, shouldShow: shouldShow, animated: animated)
    }
    
    private func showView(_ view: UIView, shouldShow: Bool, animated: Bool) {
        let duration: TimeInterval = animated ? animationSpeed : 0
        
        let targetAlpha: CGFloat
        let curve: UIViewAnimationOptions
        if shouldShow {
            targetAlpha = 1
            curve = [.curveEaseOut]
        } else {
            targetAlpha = 0
            curve = [.curveEaseIn]
        }
        
        UIView.animate(withDuration: duration, delay: 0, options: curve, animations: {
            view.alpha = targetAlpha
        })
    }
    
    // MARK: - Action Targets
    
    @objc private func leftButtonTapped() {
        guard let delegate = delegate else {
            assertionFailure("You probably want a delegate here")
            
            return
        }
        
        delegate.didTapLeftButton(in: self)
    }
    
    @objc private func rightButtonTapped() {
        guard let delegate = delegate else {
            assertionFailure("You probably want a delegate here")
            
            return
        }
        
        delegate.didTapRightButton(in: self)
    }
}
