"""Regenerate the flat UniEat app icon (requires Pillow)."""

from pathlib import Path

from PIL import Image, ImageDraw


SIZE = 1024
SCALE = 2
YELLOW = "#FFE500"
INK = "#121212"
CYAN = "#19D3E8"
CORAL = "#FF5A36"

points = [(560, 120), (265, 548), (465, 548), (400, 907), (777, 421), (554, 421)]


def scaled(values):
    return [(int(x * SCALE), int(y * SCALE)) for x, y in values]


image = Image.new("RGB", (SIZE * SCALE, SIZE * SCALE), YELLOW)
draw = ImageDraw.Draw(image)
draw.ellipse((110 * SCALE, 180 * SCALE, 230 * SCALE, 300 * SCALE), fill=CORAL)
draw.ellipse((770 * SCALE, 740 * SCALE, 900 * SCALE, 870 * SCALE), fill=CORAL)
draw.polygon(scaled([(x + 35, y + 38) for x, y in points]), fill=CYAN)
draw.polygon(scaled(points), fill=INK)

output = Path(__file__).resolve().parents[1] / "UniEatApp/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
output.parent.mkdir(parents=True, exist_ok=True)
image.resize((SIZE, SIZE), Image.Resampling.LANCZOS).save(output)
print(output)
