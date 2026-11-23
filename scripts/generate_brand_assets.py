import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description='从统一图形生成各平台图标与 TV 桌面横幅；需要 Pillow 与中文字体。')
parser.add_argument('--output', type=Path, default=root)
parser.add_argument('--font', type=Path, default=None, help='中文字体文件；留空则按平台自动查找')
options = parser.parse_args()
output = options.output

app_name = '果子乐'
background = '#101114'
accent = '#FF765F'

# TV 桌面横幅：Android TV 以 320x180dp 为基准，xhdpi 对应 640x360px。
banners = [
    ('tv_banner_hongguo', app_name),
    ('tv_banner', app_name),
    ('tv_banner_all_sources', app_name),
]


def resolve_font(explicit):
    if explicit:
        path = Path(explicit)
        if not path.exists():
            raise SystemExit(f'指定的字体不存在：{path}')
        return path
    candidates = [
        Path('C:/Windows/Fonts/msyhbd.ttc'),
        Path('C:/Windows/Fonts/msyh.ttc'),
        Path('C:/Windows/Fonts/simhei.ttf'),
        Path('C:/Windows/Fonts/simsun.ttc'),
        Path('/System/Library/Fonts/PingFang.ttc'),
        Path('/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc'),
        Path('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'),
        Path('/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc'),
        Path('/usr/share/fonts/noto-cjk/NotoSansCJK-Bold.ttc'),
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise SystemExit('未找到可用的中文字体，请用 --font 指定支持中文的字体文件')


def cjk_font(size):
    return ImageFont.truetype(str(font_path), size)


def save(image, name):
    destination = output / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination)


def vertical_gradient(size, top, bottom):
    width, height = size
    gradient = Image.new('RGB', (1, height))
    for y in range(height):
        ratio = y / max(1, height - 1)
        gradient.putpixel((0, y), tuple(
            round(top[i] + (bottom[i] - top[i]) * ratio) for i in range(3)
        ))
    return gradient.resize(size, Image.Resampling.BILINEAR)


def compose_banner(icon, label):
    width, height = 640, 360
    banner = vertical_gradient((width, height), (28, 31, 38), (12, 13, 16))
    draw = ImageDraw.Draw(banner)
    # 图标外侧柔光：让深色桌面上的横幅有层次，不至于像缺图的黑块。
    glow_size = 232
    glow = Image.new('RGBA', (glow_size, glow_size), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((0, 0, glow_size, glow_size), fill=(255, 118, 95, 46))
    glow = glow.filter(ImageFilter.GaussianBlur(26))
    banner.paste(glow, (18, (height - glow_size) // 2), glow)
    icon_side = 200
    glyph = icon.resize((icon_side, icon_side), Image.Resampling.LANCZOS)
    icon_x, icon_y = 44, (height - icon_side) // 2
    banner.paste(glyph, (icon_x, icon_y), glyph)
    # 文字基线按实际字形高度居中，避免不同字体字号上下偏移。
    name_font = cjk_font(92)
    left, top, right, bottom = draw.textbbox((0, 0), label, font=name_font)
    text_x = icon_x + icon_side + 40
    text_y = (height - (bottom - top)) // 2 - top
    draw.text((text_x, text_y), label, font=name_font, fill='white')
    # 品牌色下划线，宽度跟随文字，收尾完整不超出安全区。
    bar_top = text_y + bottom + 22
    draw.rounded_rectangle(
        (text_x + 4, bar_top, min(text_x + 4 + (right - left), width - 44), bar_top + 8),
        radius=4, fill=accent,
    )
    return banner


icon = Image.new('RGB', (1024, 1024), background)
draw = ImageDraw.Draw(icon)
draw.rounded_rectangle((110, 110, 914, 914), radius=236, fill=accent)
draw.polygon([(418, 303), (418, 721), (734, 512)], fill='white')

contents = json.loads((root / 'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json').read_text())
for entry in contents['images']:
    if 'filename' in entry:
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'].rstrip('x')))
        save(icon.resize((size, size), Image.Resampling.LANCZOS),
             'ios/Runner/Assets.xcassets/AppIcon.appiconset/' + entry['filename'])
save(icon.resize((256, 256), Image.Resampling.LANCZOS), 'windows/runner/resources/app_icon.ico')

font_path = resolve_font(options.font)
print(f'中文字体：{font_path}', flush=True)
logo_path = root / 'android/app/src/main/res/drawable-nodpi/hongguo_logo.png'
logo = Image.open(logo_path).convert('RGBA') if logo_path.exists() else icon
for resource, label in banners:
    save(compose_banner(logo, label), f'android/app/src/main/res/drawable-xhdpi/{resource}.png')
    print(f'已生成 {resource}.png（{label}）', flush=True)
