import XCTest
@testable import MarkdownEditorHy4

@MainActor
final class QuoteShotTests: XCTestCase {
    func testShot() throws {
        let path = "/Users/pan/Project/iOSDemo/MarkdownEditorHy4/testcase/cmark-gfm 常见语法精简测试文件.md"
        let md = try String(contentsOfFile: path, encoding: .utf8)
        let tv = MarkdownTextView(markdown: md)
        tv.frame = CGRect(x: 0, y: 0, width: 760, height: 1000)
        let window = UIWindow(frame: tv.frame)
        window.addSubview(tv)
        window.makeKeyAndVisible()
        tv.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        for offset in [0, 4000, 5600, 8000] {
            tv.contentOffset = CGPoint(x: 0, y: CGFloat(offset))
            tv.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let shot = UIGraphicsImageRenderer(size: tv.bounds.size).image { _ in
                tv.drawHierarchy(in: tv.bounds, afterScreenUpdates: true)
            }
            try? shot.pngData()?.write(to: URL(fileURLWithPath: "/tmp/quote_shot_\(offset).png"))
        }
    }
}
