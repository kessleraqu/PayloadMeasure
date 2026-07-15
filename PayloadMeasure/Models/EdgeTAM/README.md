# EdgeTAM Core ML models

These three on-device models were exported from Meta's pretrained EdgeTAM checkpoint with the
official `coreml/export_to_coreml.py` exporter:

- Upstream: https://github.com/facebookresearch/EdgeTAM
- Upstream revision: `7711e012a30a2402c4eaab637bdb00a521302c91`
- Checkpoint SHA-256: `ed2d4850b8792c239689b043c47046ec239b6e808a3d9b6ae676c803fd8780df`
- License: Apache License 2.0 (see `LICENSE`)

The app loads the image encoder once per camera frame, shares its embeddings across all locked
objects, and runs the prompt encoder plus mask decoder independently for each object.
