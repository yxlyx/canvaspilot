import sys
import warnings
from io import BytesIO

from PIL import Image, ImageDraw, ImageFont, ImageOps, UnidentifiedImageError

from app.services import source_previews

PREVIEW_WIDTH = 900
PREVIEW_HEIGHT = 1160
PREVIEW_MARGIN = 58
MAX_PREVIEW_PIXELS = 2_500_000
Image.MAX_IMAGE_PIXELS = 25_000_000
warnings.simplefilter("error", Image.DecompressionBombWarning)


def _apply_resource_limits() -> None:
    try:
        import resource
    except ImportError:
        return

    resource.setrlimit(
        resource.RLIMIT_CPU,
        (source_previews.MAX_PREVIEW_SECONDS, source_previews.MAX_PREVIEW_SECONDS + 1),
    )
    if sys.platform.startswith("linux"):
        memory_bytes = 384 * 1024 * 1024
        resource.setrlimit(resource.RLIMIT_AS, (memory_bytes, memory_bytes))


def _png(image: Image.Image) -> bytes:
    output = BytesIO()
    image.save(output, format="PNG", optimize=True)
    value = output.getvalue()
    if len(value) > source_previews.MAX_PREVIEW_OUTPUT_BYTES:
        raise ValueError("preview output is too large")
    return value


def _render_pdf(content: bytes) -> bytes:
    import pypdfium2

    document = pypdfium2.PdfDocument(content)
    try:
        if len(document) < 1:
            raise ValueError("PDF has no pages")
        page = document[0]
        try:
            width, height = page.get_size()
            if width <= 0 or height <= 0:
                raise ValueError("PDF page has invalid dimensions")
            scale = min(2.0, PREVIEW_WIDTH / width, PREVIEW_HEIGHT / height)
            pixel_width = max(1, round(width * scale))
            pixel_height = max(1, round(height * scale))
            if pixel_width * pixel_height > MAX_PREVIEW_PIXELS:
                raise ValueError("PDF preview exceeds the pixel limit")
            bitmap = page.render(scale=scale)
            try:
                return _png(bitmap.to_pil().convert("RGB"))
            finally:
                bitmap.close()
        finally:
            page.close()
    finally:
        document.close()


def _render_image(content: bytes) -> bytes:
    with Image.open(BytesIO(content)) as uploaded:
        if uploaded.format not in {"PNG", "JPEG"}:
            raise ValueError("unsupported image format")
        if uploaded.width * uploaded.height > 25_000_000:
            raise ValueError("image exceeds the pixel limit")
        uploaded.load()
        image = ImageOps.exif_transpose(uploaded).convert("RGB")
        image.thumbnail((PREVIEW_WIDTH, PREVIEW_HEIGHT), Image.Resampling.LANCZOS)
        canvas = Image.new("RGB", (PREVIEW_WIDTH, PREVIEW_HEIGHT), "#f7f5ef")
        left = (PREVIEW_WIDTH - image.width) // 2
        top = (PREVIEW_HEIGHT - image.height) // 2
        canvas.paste(image, (left, top))
        return _png(canvas)


def _wrap_line(draw: ImageDraw.ImageDraw, value: str, font: ImageFont.ImageFont) -> list[str]:
    available = PREVIEW_WIDTH - PREVIEW_MARGIN * 2
    words = value.expandtabs(4).split()
    if not words:
        return [""]
    lines: list[str] = []
    current = words[0]
    for word in words[1:]:
        candidate = f"{current} {word}"
        if draw.textlength(candidate, font=font) <= available:
            current = candidate
        else:
            lines.append(current)
            current = word
    lines.append(current)
    return lines


def _render_text(content: bytes) -> bytes:
    text = content.decode("utf-8", errors="replace").replace("\r\n", "\n").replace("\r", "\n")
    canvas = Image.new("RGB", (PREVIEW_WIDTH, PREVIEW_HEIGHT), "#f7f5ef")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default(size=22)
    heading_font = ImageFont.load_default(size=27)
    y = PREVIEW_MARGIN
    for raw_line in text.splitlines():
        stripped = raw_line.strip()
        is_heading = stripped.startswith("#")
        visible = stripped.lstrip("#").strip() if is_heading else raw_line
        active_font = heading_font if is_heading else font
        line_height = 36 if is_heading else 31
        for line in _wrap_line(draw, visible, active_font):
            if y + line_height > PREVIEW_HEIGHT - PREVIEW_MARGIN:
                return _png(canvas)
            draw.text((PREVIEW_MARGIN, y), line, fill="#20231f", font=active_font)
            y += line_height
        y += 13 if not stripped else 5
    return _png(canvas)


def main() -> int:
    _apply_resource_limits()
    if len(sys.argv) != 2 or sys.argv[1] not in {"pdf", "image", "text"}:
        return 2
    content = sys.stdin.buffer.read(source_previews.MAX_PREVIEW_INPUT_BYTES + 1)
    if not content or len(content) > source_previews.MAX_PREVIEW_INPUT_BYTES:
        return 1
    try:
        value = {
            "pdf": _render_pdf,
            "image": _render_image,
            "text": _render_text,
        }[sys.argv[1]](content)
    except (OSError, RuntimeError, ValueError, UnidentifiedImageError):
        return 1
    except Exception:
        return 1
    sys.stdout.buffer.write(value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
