// render-symbol.js - draw an SF Symbol into a tinted PNG, for notification
// thumbnails. JXA rather than a script that needs installing: the ObjC bridge is
// on every Mac, and PyObjC is not.
//
//   osascript -l JavaScript render-symbol.js <sf-symbol> <out.png> <RRGGBB>
//
// Browse symbol names in the SF Symbols app, or `questionmark.circle.fill`-style
// guesses; an unknown name throws rather than writing a blank file.
ObjC.import('AppKit');
const argv   = $.NSProcessInfo.processInfo.arguments.js;
const symbol = argv[4].js, out = argv[5].js, hex = argv[6].js;

const SIZE = 256;
const base = $.NSImage.imageWithSystemSymbolNameAccessibilityDescription(symbol, $());
if (!base.js) throw new Error('unknown SF Symbol: ' + symbol);
const sym = base.imageWithSymbolConfiguration(
  $.NSImageSymbolConfiguration.configurationWithPointSizeWeightScale(SIZE, 6, 3));

const rgb = [0, 2, 4].map(i => parseInt(hex.substr(i, 2), 16) / 255);
const color = $.NSColor.colorWithSRGBRedGreenBlueAlpha(rgb[0], rgb[1], rgb[2], 1.0);

// Fit the symbol inside the canvas, preserving aspect (fill variants are drawn
// edge to edge, so without this the disc gets clipped into an octagon).
const sz = sym.size;
const k = Math.min(SIZE / sz.width, SIZE / sz.height);
const w = sz.width * k, h = sz.height * k;
const rect = $.NSMakeRect((SIZE - w) / 2, (SIZE - h) / 2, w, h);

// Tint on its own canvas: SourceAtop floods the whole context, so it has to
// happen before the backing disc is drawn or it would paint over that too.
const tinted = $.NSImage.alloc.initWithSize($.NSMakeSize(SIZE, SIZE));
tinted.lockFocus;
sym.drawInRectFromRectOperationFraction(rect, $.NSZeroRect, $.NSCompositeSourceOver, 1.0);
color.set;
$.NSRectFillUsingOperation($.NSMakeRect(0, 0, SIZE, SIZE), $.NSCompositeSourceAtop);
tinted.unlockFocus;

// The .fill symbols knock the glyph out as transparent, which would let the
// banner show through and invert between light and dark mode. A white disc
// underneath pins the glyph to white in both.
const canvas = $.NSImage.alloc.initWithSize($.NSMakeSize(SIZE, SIZE));
canvas.lockFocus;
$.NSColor.whiteColor.set;
$.NSBezierPath.bezierPathWithOvalInRect($.NSInsetRect(rect, w * 0.08, h * 0.08)).fill;
tinted.drawInRectFromRectOperationFraction(
  $.NSMakeRect(0, 0, SIZE, SIZE), $.NSZeroRect, $.NSCompositeSourceOver, 1.0);
canvas.unlockFocus;

const rep = $.NSBitmapImageRep.imageRepWithData(canvas.TIFFRepresentation);
rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $())
   .writeToFileAtomically($(out), true);
