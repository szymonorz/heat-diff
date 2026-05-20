use Image;

config const n = 20,
             numSteps = 100,
             alpha = 0.25;

const fullDomain = {1..n},
      interior   = {2..n-1};

var u: [fullDomain] real = 1.0; 
// u[n/4..3*n/4] = 2.0;  // make the middle a bit hotter
u[1] = 2.0;
u[n] = 2.0;

var un = u;

var movie = new mediaPipe("heat1d.mp4", imageType.bmp, framerate=5);
proc renderFrame(frame) {

  var low = min reduce frame;
  var high = max reduce frame;

  var normalized = (frame - low) / (high - low);
  var colors1d = interpolateColor(normalized, 0xFF0000, 0x0000FF);

  var img2d: [1..1, 1..n] int;

  for j in 1..n do
      img2d[1, j] = colors1d[j];

  var big = scale(img2d, 32);

  movie.writeFrame(big);

}

for 1..numSteps {
  forall i in interior do
    u[i] = un[i] + alpha * (un[i-1] - 2*un[i] + un[i+1]);  
  un <=> u;

  renderFrame(un);
  writeln(un);
}


