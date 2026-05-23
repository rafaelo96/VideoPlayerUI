#!/usr/bin/env python3
"""
Convert a RIFE v4.x IFNet checkpoint to a Core ML .mlpackage.

Expected usage:
  python3 -m venv .venv-rife
  source .venv-rife/bin/activate
  pip install --upgrade pip
  pip install torch torchvision coremltools==7.2 pillow numpy
  PYTHONPATH=/path/to/rife python scripts/convert_rife_v4_coreml.py \
    --checkpoint /path/to/flownet.pkl \
    --rife-root /path/to/rife \
    --output /path/to/RIFE.mlpackage

The script expects a RIFE repository exposing IFNet from one of the common
locations used by RIFE v4 forks. The traced wrapper accepts:
  frame0: RGB image tensor/image, batch 1, 3x720x1280, float in [0, 1]
  frame1: RGB image tensor/image, batch 1, 3x720x1280, float in [0, 1]
  timestep: float32 tensor [1]
and returns the interpolated RGB image tensor.
"""

from __future__ import annotations

import argparse
import importlib
import json
import math
import pathlib
import sys
from typing import Any

import coremltools as ct
import numpy as np
import torch


class RIFETraceWrapper(torch.nn.Module):
    def __init__(self, model: torch.nn.Module):
        super().__init__()
        self.model = model.eval()

    def forward(self, frame0: torch.Tensor, frame1: torch.Tensor, timestep: torch.Tensor) -> torch.Tensor:
        timestep_value = timestep.reshape(1, 1, 1, 1).to(frame0.dtype)
        frames = torch.cat((frame0, frame1), dim=1)
        timestep_map = timestep_value.expand(frame0.shape[0], 1, frame0.shape[2], frame0.shape[3])
        merged = torch.cat((frames, timestep_map), dim=1)

        try:
            output = self.model(frames, timestep_value, [32, 16, 8, 4, 1])
        except TypeError:
            try:
                output = self.model(frames, timestep_value)
            except TypeError:
                # Older forks concatenate the timestep map into the image tensor.
                output = self.model(merged, [4, 2, 1])

        if isinstance(output, (tuple, list)):
            output = output[-1]
            if isinstance(output, (tuple, list)):
                output = output[-1]

        return torch.clamp(output, 0.0, 1.0)


def import_ifnet(rife_root: pathlib.Path) -> type[torch.nn.Module]:
    sys.path.insert(0, str(rife_root))
    candidates = [
        "train_log.IFNet_HDv3",
        "model.IFNet",
        "model.RIFE.IFNet",
        "train_log.IFNet",
        "IFNet",
    ]

    last_error: Exception | None = None
    for module_name in candidates:
        try:
            module = importlib.import_module(module_name)
            if hasattr(module, "IFNet"):
                return getattr(module, "IFNet")
        except Exception as exc:
            last_error = exc

    raise RuntimeError(f"Could not import IFNet from {rife_root}. Last error: {last_error}")


def load_checkpoint(model: torch.nn.Module, checkpoint: pathlib.Path) -> None:
    raw = torch.load(checkpoint, map_location="cpu")
    state: dict[str, Any]
    if isinstance(raw, dict) and "model" in raw and isinstance(raw["model"], dict):
        state = raw["model"]
    elif isinstance(raw, dict) and "state_dict" in raw and isinstance(raw["state_dict"], dict):
        state = raw["state_dict"]
    elif isinstance(raw, dict):
        state = raw
    else:
        raise RuntimeError("Unsupported checkpoint format")

    cleaned = {
        key.replace("module.", "", 1): value
        for key, value in state.items()
        if torch.is_tensor(value)
    }
    missing, unexpected = model.load_state_dict(cleaned, strict=False)
    if unexpected:
        print(f"warning: unexpected checkpoint keys: {unexpected[:8]}")
    if missing:
        print(f"warning: missing checkpoint keys: {missing[:8]}")


def psnr(a: np.ndarray, b: np.ndarray) -> float:
    mse = float(np.mean((a.astype(np.float32) - b.astype(np.float32)) ** 2))
    if mse == 0:
        return math.inf
    return 20.0 * math.log10(1.0 / math.sqrt(mse))


def run_coreml_prediction(mlmodel: ct.models.MLModel, frame0: np.ndarray, frame1: np.ndarray, t: np.ndarray) -> np.ndarray:
    prediction = mlmodel.predict({"frame0": frame0, "frame1": frame1, "timestep": t})
    output = prediction.get("interpolated")
    if output is None:
        output = next(iter(prediction.values()))
    return np.asarray(output)


def convert(args: argparse.Namespace) -> None:
    torch.set_grad_enabled(False)
    rife_root = pathlib.Path(args.rife_root).expanduser().resolve()
    checkpoint = pathlib.Path(args.checkpoint).expanduser().resolve()
    output = pathlib.Path(args.output).expanduser().resolve()

    ifnet_type = import_ifnet(rife_root)
    model = ifnet_type()
    load_checkpoint(model, checkpoint)
    wrapped = RIFETraceWrapper(model).eval()

    frame0 = torch.rand(1, 3, args.height, args.width, dtype=torch.float32)
    frame1 = torch.rand(1, 3, args.height, args.width, dtype=torch.float32)
    timestep = torch.tensor([0.5], dtype=torch.float32)

    traced = torch.jit.trace(wrapped, (frame0, frame1, timestep), strict=False, check_trace=False)
    traced = torch.jit.freeze(traced.eval())

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.ImageType(
                name="frame0",
                shape=frame0.shape,
                color_layout=ct.colorlayout.RGB,
                scale=1.0 / 255.0,
                bias=[0.0, 0.0, 0.0],
            ),
            ct.ImageType(
                name="frame1",
                shape=frame1.shape,
                color_layout=ct.colorlayout.RGB,
                scale=1.0 / 255.0,
                bias=[0.0, 0.0, 0.0],
            ),
            ct.TensorType(name="timestep", shape=(1,), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="interpolated")],
    )

    mlmodel.short_description = "RIFE v4.x IFNet frame interpolation"
    mlmodel.author = "RIFE authors; converted for Rift"
    mlmodel.license = "See source checkpoint license"
    mlmodel.version = args.rife_version
    mlmodel.user_defined_metadata.update(
        {
            "model": "RIFE IFNet",
            "rife_version": args.rife_version,
            "max_width": str(args.width),
            "max_height": str(args.height),
            "input_format": "RGB, float normalized via Core ML ImageType scale",
            "timestep": "float32 tensor shape [1]",
            "conversion_note": (
                "If coremltools fails on grid_sample/warping, use a RIFE fork whose "
                "bilinear warp lowers to Core ML MIL ops, or replace the warp module "
                "with a custom MIL op/Core ML custom layer before conversion."
            ),
        }
    )

    output.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(output))

    compiled = ct.models.MLModel(str(output), compute_units=ct.ComputeUnit.ALL)
    with torch.no_grad():
        torch_out = wrapped(frame0, frame1, timestep).detach().cpu().numpy()

    # coremltools ImageType accepts NHWC image-like arrays for predict on macOS.
    frame0_nhwc = np.transpose(frame0.numpy(), (0, 2, 3, 1))
    frame1_nhwc = np.transpose(frame1.numpy(), (0, 2, 3, 1))
    coreml_out = run_coreml_prediction(compiled, frame0_nhwc, frame1_nhwc, timestep.numpy())

    if coreml_out.shape != torch_out.shape:
        if coreml_out.ndim == 4 and coreml_out.shape[-1] == 3:
            coreml_out = np.transpose(coreml_out, (0, 3, 1, 2))
        else:
            raise RuntimeError(f"Unexpected Core ML output shape {coreml_out.shape}, expected {torch_out.shape}")

    score = psnr(torch_out, coreml_out)
    report = {
        "output": str(output),
        "psnr": score,
        "width": args.width,
        "height": args.height,
        "rife_version": args.rife_version,
    }
    print(json.dumps(report, indent=2))
    if score < 40.0:
        raise RuntimeError(f"PSNR validation failed: {score:.2f} dB < 40 dB")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True, help="Path to RIFE flownet.pkl")
    parser.add_argument("--rife-root", required=True, help="Path to cloned RIFE repository")
    parser.add_argument("--output", required=True, help="Output .mlpackage path")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--rife-version", default="v4.x")
    return parser.parse_args()


if __name__ == "__main__":
    convert(parse_args())
