# Third-party software and model notices

Local Dictation installs these packages into a private Python environment only when an MLX model is selected:

- [MLX](https://github.com/ml-explore/mlx), MIT License.
- [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper), MIT License.
- [mlx-lm](https://github.com/ml-explore/mlx-lm), MIT License.
- [Transformers](https://github.com/huggingface/transformers/blob/v5.22.1/LICENSE), Apache License 2.0.
- [Hugging Face Hub](https://github.com/huggingface/huggingface_hub), Apache License 2.0.
- [PyTorch](https://github.com/pytorch/pytorch/blob/v2.15.0/LICENSE), BSD 3-Clause License, required by the mlx-whisper package metadata.

Runtime versions are MLX 0.31.2, mlx-whisper 0.4.3, mlx-lm 0.31.2, Transformers 5.22.1, PyTorch 2.15.0 for Whisper, and Hugging Face Hub 1.33.0. Apple silicon/Python 3.12 dependency profiles are pinned with wheel hashes in `requirements/`; only the selected speech and cleanup profiles are installed.

The model cards are [Whisper Tiny English](https://huggingface.co/mlx-community/whisper-tiny.en-mlx-4bit), [Whisper Base English](https://huggingface.co/mlx-community/whisper-base.en-mlx-q4), and [Whisper Large v3 Turbo](https://huggingface.co/mlx-community/whisper-large-v3-turbo). They link to [OpenAI Whisper](https://github.com/openai/whisper), released under MIT. The MLX conversion cards do not state a separate license for the converted weight files. Their use is subject to the upstream Whisper model terms and any applicable rights in the converted files.

The Qwen3 model cards state Apache License 2.0. See the [0.6B card](https://huggingface.co/mlx-community/Qwen3-0.6B-4bit) and [1.7B card](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit).

Apple Speech is provided by macOS and is not bundled here.
