// render-pi-logo.js - draw the pi mark into a PNG, for the notification bundle
// icon. JXA for the same reason as render-symbol.js: the ObjC bridge is on every
// Mac, and librsvg is not.
//
//   osascript -l JavaScript render-pi-logo.js <out.png> <size> [markRRGGBB] [bgRRGGBB]
//
// The mark is pi.dev's, and it is pure rectilinear geometry on a 470 unit grid,
// so it is drawn from its own coordinates rather than rasterised from the SVG.
// That keeps the build offline, and keeps the edges sharp at 16px, where
// downscaling a large render smears a blocky logo into grey.
ObjC.import('AppKit');

const argv = $.NSProcessInfo.processInfo.arguments.js;
const OUT  = argv[4].js;
const SIZE = parseInt(argv[5].js, 10);
const MARK = argv.length > 6 ? argv[6].js : '1A1A1A';
const BG   = argv.length > 7 ? argv[7].js : 'F2F0E9';

if (!(SIZE > 0)) throw new Error('size must be a positive integer');

const color = (hex) => {
  const c = [0, 2, 4].map((i) => parseInt(hex.substr(i, 2), 16) / 255);
  return $.NSColor.colorWithSRGBRedGreenBlueAlpha(c[0], c[1], c[2], 1.0);
};

// Straight off pi.dev, in its own 470-unit space with y pointing down:
//   path1  M0 0 H352.07 V234.71 H234.71 V352.07 H117.36 V469.43 H0 Z
//   hole   M117.36 117.36 V234.71 H234.71 V117.36 Z   (evenodd counter)
//   path2  M352.07 234.71 H469.43 V469.43 H352.07 Z   (the stem)
const EXTENT = 469.43;
const BODY = [
  [0, 0], [352.07, 0], [352.07, 234.71], [234.71, 234.71],
  [234.71, 352.07], [117.36, 352.07], [117.36, 469.43], [0, 469.43],
];
const HOLE = [117.36, 117.36, 234.71, 234.71];
const STEM = [352.07, 234.71, 469.43, 469.43];

// Leave the mark room to breathe: an app icon that runs edge to edge reads as
// larger than its neighbours in Notification Center.
const scale = (SIZE * 0.60) / EXTENT;
const originX = (SIZE - EXTENT * scale) / 2;
const originY = (SIZE - EXTENT * scale) / 2;

// AppKit's origin is bottom-left and the logo's is top-left, so y inverts.
const px = (x) => originX + x * scale;
const py = (y) => originY + (EXTENT - y) * scale;
const rect = (x0, y0, x1, y1) =>
  $.NSMakeRect(px(x0), py(y1), (x1 - x0) * scale, (y1 - y0) * scale);

const canvas = $.NSImage.alloc.initWithSize($.NSMakeSize(SIZE, SIZE));
canvas.lockFocus;

// A plate behind the mark. The logo is a single flat colour with a knocked-out
// counter, so on its own it would vanish against a dark banner and its counter
// would fill with whatever showed through.
const pad = SIZE * 0.06;
color(BG).set;
$.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius(
  $.NSMakeRect(pad, pad, SIZE - pad * 2, SIZE - pad * 2),
  SIZE * 0.20, SIZE * 0.20,
).fill;

color(MARK).set;
const body = $.NSBezierPath.bezierPath;
body.moveToPoint($.NSMakePoint(px(BODY[0][0]), py(BODY[0][1])));
for (const [x, y] of BODY.slice(1)) body.lineToPoint($.NSMakePoint(px(x), py(y)));
body.closePath;
body.fill;
$.NSBezierPath.bezierPathWithRect(rect(...STEM)).fill;

// Punch the counter back out in the plate colour. Simpler than an even-odd
// subpath, and identical in result because it always sits over the plate.
color(BG).set;
$.NSBezierPath.bezierPathWithRect(rect(...HOLE)).fill;

canvas.unlockFocus;

const rep = $.NSBitmapImageRep.imageRepWithData(canvas.TIFFRepresentation);
rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $())
   .writeToFileAtomically($(OUT), true);
