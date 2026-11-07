import AppKit
// Biblio simgesi: teal zemin, serif B, sarı çizgi, turuncu ayraç. Kullanım: swift make_icon.swift <çıktı.png>
let S: CGFloat = 1024, k = S / 180
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
// SVG koordinatı (üstten) -> CG (alttan)
func r(_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ h: CGFloat) -> CGRect { CGRect(x: x*k, y: S-(y+h)*k, width: w*k, height: h*k) }
func P(_ x: CGFloat,_ y: CGFloat) -> CGPoint { CGPoint(x: x*k, y: S-y*k) }
let bg = CGPath(roundedRect: r(0,0,180,180), cornerWidth: 40*k, cornerHeight: 40*k, transform: nil)
ctx.addPath(bg); ctx.clip()
NSColor(red: 0x0f/255, green: 0x76/255, blue: 0x6e/255, alpha: 1).setFill(); ctx.fill(r(0,0,180,180))
// ayraç
let bm = CGMutablePath()
bm.move(to: P(130,0)); bm.addLine(to: P(154,0)); bm.addLine(to: P(154,54)); bm.addLine(to: P(142,45)); bm.addLine(to: P(130,54)); bm.closeSubpath()
ctx.addPath(bm); NSColor(red: 0xe8/255, green: 0x74/255, blue: 0x3b/255, alpha: 1).setFill(); ctx.fillPath()
// B
let font = NSFont(name: "Georgia-Bold", size: 120*k) ?? NSFont.boldSystemFont(ofSize: 120*k)
let str = NSAttributedString(string: "B", attributes: [.font: font, .foregroundColor: NSColor.white])
let w = str.size().width
str.draw(at: CGPoint(x: S/2 - w/2, y: S - 128*k + font.descender))
// sarı çizgi
let bar = CGPath(roundedRect: r(62,142,56,7), cornerWidth: 3*k, cornerHeight: 3*k, transform: nil)
ctx.addPath(bar); NSColor(red: 0xfc/255, green: 0xd3/255, blue: 0x4d/255, alpha: 1).setFill(); ctx.fillPath()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
