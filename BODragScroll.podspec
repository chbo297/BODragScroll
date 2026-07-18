Pod::Spec.new do |s|
  s.name         = "BODragScroll"
  s.version      = "1.0.1"
  s.summary      = "Draggable card scroll panel with nested scrollView support (Swift)."
  s.description  = "Swift port of BODragScrollView: a draggable card-style panel that coordinates with multi-level nested UIScrollViews."

  s.homepage     = "https://github.com/chbo297/BODragScroll"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.author       = { "bo" => "chbo297@gmail.com" }

  s.platform     = :ios, "13.0"
  s.swift_version = "5.7"
  s.source       = {
                     :git => "https://github.com/chbo297/BODragScroll.git",
                     :tag => s.version
  }

  s.source_files = "Sources/BODragScroll/**/*.swift"
  s.framework    = "UIKit"
end
