# smallpt-cr

A Crystal port of [smallpt](http://www.kevinbeason.com/smallpt/), Kevin Beason's
famous ~100-line unbiased path tracer, written to explore the performance gap
between optimized C++ and optimized Crystal.

> **📖 This is literate programming.** The source code is written to be *read*:
> every section of the algorithm is explained in prose, side by side with the
> code that implements it. Start here:
> **[Read the annotated, literate source](https://ralsina.github.io/smallpt-cr/src/smallpt.cr.html)** —
> it's the best way to understand both the path tracing algorithm and this port.

![Rendered scene](assets/render.png)

*The classic smallpt scene: two diffuse walls (red and blue), a mirror sphere
and a glass sphere, lit only by a spherical light, rendered at 800 samples per
pixel. Rendered by the Crystal implementation.*

## What is smallpt?

smallpt is a global illumination renderer written by Kevin Beason in 2006 as a
demonstration that physically-based rendering could fit in about 100 lines of
C++. It is a *path tracer*: instead of computing light analytically, it shoots
millions of random rays from the camera and follows their bounces around the
scene, averaging the results. Given enough samples this converges to the
mathematically correct image — no shortcuts, no fake ambient occlusion maps.

Its tricks are the classics of Monte Carlo rendering:

- **Cosine-weighted importance sampling** for diffuse bounces, so more rays go
  where the lighting contribution is largest.
- **Russian roulette** to randomly kill deep ray paths, keeping renders finite
  without biasing the result.
- **Fresnel-based probabilistic reflection/refraction** for the glass sphere.
- **Tent-filtered supersampling** with 2×2 subpixels per camera sample.

Because it is tiny, self-contained and computationally brutal, smallpt became a
popular language benchmark: ports exist for dozens of languages, and "how fast
can your language render N samples" became a standard shootout.

## This project

This repository contains:

<table>
  <tr><th>File</th><th>Description</th></tr>
  <tr><td><code>smallpt.cpp</code></td><td>The original algorithm, compiled with <code>g++ -O3</code></td></tr>
  <tr><td><code>src/smallpt.cr</code></td><td>A faithful Crystal port, built with <code>shards build --release</code></td></tr>
</table>

The port is deliberately *algorithmically identical*: same scene, same camera,
same sampling strategy, same math. Both implementations are single code paths
that were then parallelized in the idiomatic way for each language:

- **C++**: OpenMP (`#pragma omp parallel for` over scanlines), as in the
  original source.
- **Crystal**: fibers distributed over an execution context sized to the CPU
  count, with each row claiming work from a shared atomic counter.

Each row has its own deterministic random number stream, so output is
reproducible regardless of thread scheduling.

### Literate documentation

The Crystal source is written in literate style: the prose comments that
explain the algorithm are the documentation. The rendered version is published
at [ralsina.github.io/smallpt-cr](https://ralsina.github.io/smallpt-cr/) and
can be regenerated locally with:

```console
$ crycco README.md src/smallpt.cr
```

## Expressiveness: C++ vs Crystal

The C++ original is famously terse — it reads like compressed mathematics:
one-letter variables (`r`, `f`, `nl`, `ddn`), operator overloading doing double
duty (`%` is cross product), implicit conversions everywhere, and all three
material types dispatched inside one deeply nested function. It's brilliant,
and nearly unreadable without the accompanying notes.

The Crystal port keeps the same structure but can afford to be descriptive
without any runtime cost, because structs are unboxed value types:

- `record Vec` with named methods (`#norm`, `#dot`, `#mult`) instead of
  overloaded operators.
- A `ReflT` enum (`Diffuse`, `Specular`, `Refractive`) instead of integer
  constants, dispatched with an exhaustive `case`.
- Descriptive names throughout: `subpixel_x`, `accumulated`,
  `reflection_type`, `reflected_ray`.
- Each material's shading logic lives in its own branch or helper method
  (`radiance_refractive`) rather than nested ternaries.

The interesting result: **none of that readability costs performance**. The
Crystal version compiles down to essentially the same machine code patterns —
stack-allocated vectors, no GC pressure in the hot loop, monomorphic dispatch.

## Performance

### Single-threaded, four languages

To widen the comparison, this repository also vendors two third-party
implementations of the same algorithm (see `third_party/`):

- Rust: [mjm114514/smallpt-rs](https://github.com/mjm114514/smallpt-rs),
  patched to use a single worker thread for a fair comparison
- Go: [ShadowIce/smallpt.go](https://github.com/ShadowIce/smallpt.go), already
  single-threaded

All four render the same scene with the same sampling strategy:

<table>
  <tr><th>Implementation</th><th>128 spp</th><th>Relative</th></tr>
  <tr><td>C++ <code>-O3</code></td><td align="right">~112.6s</td><td align="right">1.00</td></tr>
  <tr><td>Rust (<code>rustc -C opt-level=3</code>)</td><td align="right">~115.4s</td><td align="right">1.02</td></tr>
  <tr><td>Crystal <code>--release</code></td><td align="right">~117.6s</td><td align="right">1.04</td></tr>
  <tr><td>Go (<code>go build</code>, default GC)</td><td align="right">~132.9s</td><td align="right">1.18</td></tr>
</table>

**Disclaimer:** these numbers come from *one* machine (a 12-core Linux
desktop), one workload, and best-of-two runs. Your mileage will vary with CPU,
compiler versions, and even compiler flags. Treat them as an anecdote, not a
benchmark suite.

The takeaway: C++, Rust, and Crystal are within ~5% of each other — compiled,
ahead-of-time languages with unboxed value types are all effectively at parity
on numeric workloads like this. Go trails by ~18%, plausibly due to bounds
checking and GC interaction in the hot loop.

### Multi-threaded

Measured on the same 12-core desktop (1024×768, best of runs):

<table>
  <tr><th>Implementation</th><th>128 spp</th><th>Speedup vs own serial</th></tr>
  <tr><td>C++ <code>-O3 -fopenmp</code>, 12 threads</td><td align="right">~14.6s</td><td align="right">7.7x</td></tr>
  <tr><td>Crystal <code>--release</code>, execution contexts</td><td align="right">~15.1s</td><td align="right">8.0x</td></tr>
</table>

**The C++ vs Crystal gap is about 5%**, both serial and parallel — effectively
parity. Crystal's ahead-of-time compilation, unboxed structs, and lack of
garbage collection pressure in numeric hot loops make it a very credible
replacement for C++ on this kind of workload.

Caveats worth knowing:

- The comparison uses `--release`; debug-mode Crystal is roughly an order of
  magnitude slower.
- Since Crystal 1.21, programs start with parallelism set to 1; you must call
  `Fiber::ExecutionContext.default.resize(worker_count)` (as this port does)
  or set `CRYSTAL_WORKERS`.

## Building and running

```console
$ shards install          # no dependencies, but harmless
$ shards build --release  # builds bin/smallpt
$ g++ -O3 -o bin/smallpt-cpp smallpt.cpp            # serial C++
$ g++ -O3 -fopenmp -o bin/smallpt-cpp-mt smallpt.cpp # parallel C++
$ (cd third_party/smallpt-rs && cargo build --release)   # vendored Rust port
$ go build -o /tmp/smallpt-go third_party/smallpt.go/smallpt.go # vendored Go port

$ bin/smallpt 500         # render 500 spp (samples/4 subpixel passes)
$ bin/smallpt-cpp-mt 500
$ SMALLPT_WORKERS=1 bin/smallpt 500  # force single-threaded rendering
```

All write `image.ppm` (P3 ASCII format) to the current directory, except the
Rust port which writes `res.png`.

### Lint

```console
$ ameba
```
