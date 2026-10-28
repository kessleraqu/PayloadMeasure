# PayloadMeasure

iOS app for my Master's thesis, *Using Computer Vision for Guiding Payload Distribution in Modular
Drone Delivery Systems*. It measures payload objects with the iPhone's LiDAR camera, suggests a box
for each one and then plans how to load the boxes into a drone payload module so that the centre of
mass stays balanced. It also runs the user study and the accuracy tests used in the thesis.

## Requirements

- Xcode 26 and iOS 26.5
- An iPhone or iPad with LiDAR for AR measurement (the manual mode works on any device)

Open `PayloadMeasure.xcodeproj`, select the `PayloadMeasure` scheme and run it on a device. The unit
tests run in the simulator.

## Before the first run: add your boxes

The app ships without any boxes. Until you add some, no object will fit and everything has to be
marked as already being a box.

1. On the **New study run** screen, scroll to **Package boxes**.
2. Tap **Big box** or **Small box**. Each payload module has its own list.
3. Enter the outer length, width and height in millimetres and tap **Add box**. If the inside of
   the box is a different size, turn on **Interior differs from outer footprint** and enter the
   inside measurements too.

The lists are saved on the device. The app always assigns the smallest box an object fits in, in
any orientation.

## Code overview

| Folder | What it does |
| --- | --- |
| `AR/` | ARKit session, the camera view and its coordinator (scan loop, support plane, drawing) and the ARView shared between screens |
| `Capture/` | Object segmentation with Vision, keeping masks on the right object, and fitting a box to the LiDAR points (Liu et al. / Zhang et al.) |
| `Measurement/` | Measurement modes and the rules for when a measurement starts and when it has converged |
| `Manual/` | Entering object sizes by hand, used for the no-AR study condition |
| `Packing/` | Box assignment, package preparation and the loading plan screens |
| `Packing/Knapsack/` | 3D knapsack heuristic with full support and centre-of-mass constraints, based on Baldi et al. |
| `Packing/Balance/` | Alternative MILP formulation with a small simplex / branch-and-bound solver |
| `Study/` | User study setup, phase timing, saving runs and exporting reports |
| `Accuracy/` | Repeatability and framing accuracy tests |
| `LiDAR/` | Separate tool that captures one frame as RGB, depth points and both combined |
| `Utilities/` | Small helpers |

`MeasurementOverlayView.swift` is the HUD on top of the camera and `ContentView.swift` connects the
study flow to the measuring and packing screens.

Study runs and test results are saved in the app's Documents folder, which is also visible in the
Files app.

## References

**3D knapsack** (`Packing/Knapsack/`)
> M. M. Baldi, G. Perboli, R. Tadei, "The three-dimensional knapsack problem with balancing
> constraints", *Applied Mathematics and Computation* 218 (2012) 9802–9818.

> L. Junqueira, R. Morabito, D. S. Yamashita, "Three-dimensional container loading models with cargo
> stability and load bearing constraints", *Computers & Operations Research* 39 (2012) 74–85.

**Balance arrangement** (`Packing/Balance/`)
> B. L. Kaluzny, R. H. A. D. Shaw, "Optimal aircraft load balancing", *International Transactions in
> Operational Research* 16 (2009) 767–787.

**Bounding box fitting** (`Capture/ObjectCapture.swift`)
> Y. Liu, B. Liu, H. Zhang, "Estimation of 2D bounding box orientation with convex-hull points – a
> quantitative evaluation on accuracy and efficiency", *IEEE Intelligent Vehicles Symposium*, 2020.

> X. Zhang, W. Xu, C. Dong, J. M. Dolan, "Efficient L-shape fitting for vehicle detection using
> laser scanners", *IEEE Intelligent Vehicles Symposium*, 2017.

**Mask placement and point carving** (`Capture/MaskDisplayTransform.swift`, `AR/ARCameraView.swift`)
> S. Umeyama, "Least-squares estimation of transformation parameters between two point patterns",
> *IEEE Transactions on Pattern Analysis and Machine Intelligence* 13(4) (1991) 376–380.

> R. Hartley, A. Zisserman, *Multiple View Geometry in Computer Vision*, 2nd ed., Cambridge University
> Press, 2004.

> A. Laurentini, "The visual hull concept for silhouette-based image understanding", *IEEE
> Transactions on Pattern Analysis and Machine Intelligence* 16(2) (1994) 150–162.

> K. N. Kutulakos, S. M. Seitz, "A theory of shape by space carving", *International Journal of
> Computer Vision* 38(3) (2000) 199–218.

**Measurement stopping rule** (`Measurement/MeasurementConvergence.swift`)
> Y. S. Chow, H. Robbins, "On the asymptotic theory of fixed-width sequential confidence intervals
> for the mean", *Annals of Mathematical Statistics* 36(2) (1965) 457–462.

**Accuracy statistics** (`Accuracy/AccuracyTest.swift`)
> ISO 5725-2 and ISO 5725-6, *Accuracy (trueness and precision) of measurement methods and results*.

> J. M. Bland, D. G. Altman, "Statistical methods for assessing agreement between two methods of
> clinical measurement", *The Lancet* 327(8476) (1986) 307–310.
