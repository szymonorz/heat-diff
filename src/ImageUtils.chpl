module ImageUtils {
  public use Image;

  config const render = false;
  config const movieName = "heat.mp4";

  config const framerate = 10;

  config const imageHeight = 256;
  config const imageWidth = 512;

  proc makeEvenSize(img: [] int) {
    const H = img.domain.dim(0).size;
    const W = img.domain.dim(1).size;

    const newH = (if H % 2 == 0 then H else H+1);
    const newW = (if W % 2 == 0 then W else W+1);

    var output: [1..newH, 1..newW] int;

    for i in 1..newH do
        for j in 1..newW do
            output[i, j] = if i <= H && j <= W then img[i, j] else 0;

    return output;
  }

  proc resizeNearest(src: [] int, targetH: int, targetW: int) {
    const H = src.domain.dim(0).size,
            W = src.domain.dim(1).size;

    var output: [1..targetH, 1..targetW] int;

    for i in 1..targetH {
        const y = ((i-1):real * (H-1):real) / (targetH-1):real;
        const iy = max(1, min(H, round(y):int));

        for j in 1..targetW {
            const x = ((j-1):real * (W-1):real) / (targetW-1):real;
            const ix = max(1, min(W, round(x):int));
            output[i, j] = src[iy, ix];
        }
    }

    return output;
  }

  private proc _interpolateColor(data: [?d] real) {
    var low  = min reduce data;
    var high = max reduce data;

    var output: [data.domain] int;

    for idx in data.domain {
        var t = (data[idx] - low) / (high - low + 1e-10);
        const hue = 240.0 * t;
        const s = 1.0;
        const v = 1.0;

        const h6 = hue / 60.0;
        const i = floor(h6):int;
        const f = h6 - i;
        const p = v*(1-s);
        const q = v*(1-f*s);
        const w = v*(1-(1-f)*s);

        var r,g,b: real;
        select (i % 6) {
        when 0 { r=v; g=w; b=p; }
        when 1 { r=q; g=v; b=p; }
        when 2 { r=p; g=v; b=w; }
        when 3 { r=p; g=q; b=v; }
        when 4 { r=w; g=p; b=v; }
        when 5 { r=v; g=p; b=q; }
        }

        output[idx] = (0xFF << 24) | ((r*255):int << 16) | ((g*255):int << 8) | (b*255):int;
    }

    return output;
  }

  private proc processFrame(data: [?d]) where d.isRectangular() && d.rank == 1 {
    var data2d: [0..#imageHeight, d.lowBound..d.highBound] data.eltType;
    for i in 0..#imageHeight do
      data2d[i,..] = data;

    return processFrame(data2d);
  }
  private proc processFrame(data: [?d]) where d.isRectangular() && d.rank == 2 {
    var image: [data.domain] int;
    image[data.domain] = _interpolateColor(data);

    var resized = resizeNearest(image, imageHeight, imageWidth);
    return makeEvenSize(resized);
  }

  proc renderFrame(u: []) throws {
      if !render then return;
      on Locales[0] {
        @functionStatic
        ref pipe = try! new mediaPipe(movieName, imageType.bmp, framerate);
        pipe.writeFrame(processFrame(u));
      }
  }
}