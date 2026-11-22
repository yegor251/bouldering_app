"""Download the ClimbInst dataset (ClimbVision/ClimbInst) from HuggingFace.

License: CC BY-NC-SA 4.0 (non-commercial). Fine for MVP/research,
needs replacement before any commercial release.
"""

from huggingface_hub import snapshot_download

REPO_ID = "ClimbVision/ClimbInst"
LOCAL_DIR = "data/climbinst"


def main() -> None:
    snapshot_download(
        repo_id=REPO_ID,
        repo_type="dataset",
        local_dir=LOCAL_DIR,
        allow_patterns=["train/*", "validation/*", "test/*", "README.md", "LICENSE"],
    )
    print(f"Downloaded to {LOCAL_DIR}")


if __name__ == "__main__":
    main()
