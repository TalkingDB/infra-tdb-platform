#!/usr/bin/env python3

import json
import os

from common import (
    clone_repository,
    current_commit,
    load_repos,
    run,
    temporary_workspace,
)

# Configuration for repositories that produce Docker images.
DOCKER_CONFIG = {
    "module-ttt": {
        "enabled": "DOCKER_MODULE_TTT",
        "strategy": "MODULE_TTT_TAG_STRATEGY",
        "custom": "MODULE_TTT_CUSTOM_TAG",
        "image": "talkingdb/ttt",
    },
    "package-content-elementizer": {
        "enabled": "DOCKER_CONTENT_ELEMENTIZER",
        "strategy": "CONTENT_ELEMENTIZER_TAG_STRATEGY",
        "custom": "CONTENT_ELEMENTIZER_CUSTOM_TAG",
        "image": "talkingdb/ce",
    },
    "package-named-entity-linker": {
        "enabled": "DOCKER_NAMED_ENTITY_LINKER",
        "strategy": "NAMED_ENTITY_LINKER_TAG_STRATEGY",
        "custom": "NAMED_ENTITY_LINKER_CUSTOM_TAG",
        "image": "talkingdb/nel",
    },
}


def enabled(env_name: str) -> bool:
    return os.getenv(env_name, "false").lower() == "true"


def load_strategy(env_name: str):
    try:
        return [tag.strip() for tag in os.getenv(env_name, "").split(",") if tag.strip()]
    except Exception:
        return []


def tags_for(repo_name: str, commit: str):
    cfg = DOCKER_CONFIG[repo_name]

    strategy = load_strategy(cfg["strategy"])

    tags = []

    if "latest" in strategy:
        tags.append("latest")

    if "commit" in strategy:
        tags.append(commit)

    if "custom" in strategy:
        custom = os.getenv(cfg["custom"], "").strip()
        if custom:
            tags.append(custom)

    # Preserve order while removing duplicates.
    return list(dict.fromkeys(tags))


def build(repo_path, local_image):
    run(
        [
            "docker",
            "build",
            "-t",
            f"{local_image}:latest",
            ".",
        ],
        cwd=repo_path,
    )


def push(local_image, remote_image, tags):
    for tag in tags:
        run(
            [
                "docker",
                "tag",
                f"{local_image}:latest",
                f"{remote_image}:{tag}",
            ]
        )

    for tag in tags:
        run(
            [
                "docker",
                "push",
                f"{remote_image}:{tag}",
            ]
        )


def process_repo(workspace, repo):
    repo_path, repo_name = clone_repository(workspace, repo)

    try:
        cfg = DOCKER_CONFIG.get(repo_name)

        if cfg is None:
            print(f"Skipping {repo_name} (not a Docker project)")
            return

        if not enabled(cfg["enabled"]):
            print(f"Skipping {repo_name} (disabled)")
            return

        commit = current_commit(repo_path)
        tags = tags_for(repo_name, commit)

        if not tags:
            print(f"No tags requested for {repo_name}. Skipping.")
            return

        print("=" * 80)
        print(f"Building {repo_name}")
        print("=" * 80)

        print("Tags:", ", ".join(tags))

        build(repo_path, repo_name)

        push(
            repo_name,
            cfg["image"],
            tags,
        )

        print(f"✓ Published {cfg['image']}")

    except Exception as ex:
        print(f"Error processing {repo_name}: {ex}")


def main():
    repos = load_repos()

    workspace = temporary_workspace()

    for repo in repos:
        process_repo(workspace, repo)

    workspace.cleanup()


if __name__ == "__main__":
    main()
