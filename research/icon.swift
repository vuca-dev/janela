import AppKit
let S=1024; let r=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:S,pixelsHigh:S,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:r); let c=NSGraphicsContext.current!.cgContext
let body=CGPath(roundedRect:CGRect(x:100,y:100,width:824,height:824),cornerWidth:186,cornerHeight:186,transform:nil); c.addPath(body); c.clip()
let cs=CGColorSpaceCreateDeviceRGB()
let g=CGGradient(colorsSpace:cs,colors:[NSColor(red:0.10,green:0.13,blue:0.32,alpha:1).cgColor,NSColor(red:0.86,green:0.36,blue:0.34,alpha:1).cgColor,NSColor(red:1,green:0.74,blue:0.38,alpha:1).cgColor] as CFArray,locations:[0,0.62,1])!
c.drawLinearGradient(g,start:CGPoint(x:512,y:924),end:CGPoint(x:512,y:400),options:[.drawsAfterEndLocation])
c.setFillColor(NSColor(red:1,green:0.93,blue:0.72,alpha:1).cgColor); c.fillEllipse(in:CGRect(x:352,y:280,width:320,height:320))
c.setStrokeColor(NSColor(red:1,green:0.93,blue:0.72,alpha:1).cgColor); c.setLineWidth(30); c.setLineCap(.round)
for a in stride(from:15.0,through:165.0,by:30.0){let t=a * .pi/180; c.move(to:CGPoint(x:512+cos(t)*215,y:440+sin(t)*215)); c.addLine(to:CGPoint(x:512+cos(t)*290,y:440+sin(t)*290))}; c.strokePath()
c.setFillColor(NSColor(red:0.09,green:0.09,blue:0.20,alpha:1).cgColor); c.fill(CGRect(x:0,y:100,width:1024,height:340))
NSGraphicsContext.current=nil
try! r.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
