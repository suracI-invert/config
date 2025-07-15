# /// script
# requires-python = ">=3.13"
# dependencies = []
# ///

import os
import shutil
import urllib.request
import tarfile
import subprocess
from urllib.parse import urlparse


def get_filename_from_header(ret) -> str | None:
    headers = ret.getheaders()
    for k, v in headers:
        if k == "Content-Disposition" and "filename=" in v:
            filename = v.split("filename=")[-1].strip('"')
            return filename


def get_filename_from_url(url: str):
    # Fallback: extract from URL path
    parsed_url = urlparse(url)
    filename = os.path.basename(parsed_url.path)
    return filename


def get_filename(ret, url: str):
    v = get_filename_from_header(ret)
    if v:
        return v
    return get_filename_from_url(url)


def get_content_length(ret):
    headers = ret.getheaders()
    for k, v in headers:
        if k == "Content-Length":
            return int(v)


CHUNK_SIZE = 1024  # 1 MB

RIPGREP_URL = "https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep_14.1.1-1_amd64.deb"
FD_URL = "https://github.com/sharkdp/fd/releases/download/v10.2.0/fd_10.2.0_amd64.deb"
FZF_URL = "https://github.com/junegunn/fzf/releases/download/v0.64.0/fzf-0.64.0-linux_amd64.tar.gz"
LAZYGIT_URL = "https://github.com/jesseduffield/lazygit/releases/download/v0.53.0/lazygit_0.53.0_Linux_x86_64.tar.gz"

TEMP = "temp"
# DEFAULT_DST = os.path.expanduser("~/.local")
DEFAULT_DST = "local"
os.makedirs(TEMP, exist_ok=True)


def download(url: str):
    with urllib.request.urlopen(url) as response:
        if response.getcode() != 200:
            raise ValueError("Download failed")
        content_length = get_content_length(response)
        filename = get_filename(response, url)
        with open(f"{TEMP}/{filename}", "wb") as f:
            while chunk := response.read(CHUNK_SIZE):
                f.write(chunk)

        return filename


def install_tar_gz(tar_url: str, temp_dir: str):
    print(f"Installing tar.gz from {tar_url}")
    filename = download(tar_url)
    os.makedirs(temp_dir, exist_ok=True)
    with tarfile.open(f"{TEMP}/{filename}", "r:gz") as tar:
        tar.extractall(path=temp_dir)

    return filename


def install_deb(deb_url: str):
    print(f"Installing .deb from {deb_url}")
    filename = download(deb_url)
    subprocess.run(["dpkg", "-x", f"{TEMP}/{filename}", TEMP])

    return filename


def resolve_symlinks(src: str, dst: str):
    symlinks_tuple = []
    for root, dirs, files in os.walk(src):
        for name in files:
            file_path = os.path.join(root, name)
            if os.path.islink(file_path):
                target = os.readlink(file_path)
                new_filepath = os.path.join(dst, os.path.relpath(file_path, src))
                symlinks_tuple.append((new_filepath, file_path, target))
    return symlinks_tuple


def write_to_config_file(lines: list[str], path: str):
    with open(path, "a") as f:
        s = "\n\n"
        for line in f.readlines():
            for _l in lines:
                if line.strip() == _l:
                    continue
                s += _l
                s += "\n"
        f.write(s)


def run(shell: str = "zsh"):
    try:
        rip_fname = install_deb(RIPGREP_URL)
        fname = install_deb(FD_URL)

        symlinks = resolve_symlinks(f"{TEMP}/usr", DEFAULT_DST)
        for _, file_path, _ in symlinks:
            os.remove(file_path)
        print("Resolving symlinks...")
        for new_filepath, _, target in symlinks:
            try:
                os.symlink(target, new_filepath)
            except Exception as e:
                print(f"Failed to create symlink {new_filepath} -> {target}: {e}")

        print("Copying files to destination...")
        shutil.copytree(f"{TEMP}/usr", DEFAULT_DST, dirs_exist_ok=True)

        temp_dir = f"{TEMP}/fzf"
        fname = install_tar_gz(FZF_URL, temp_dir)
        shutil.copytree(f"{temp_dir}", f"{DEFAULT_DST}/bin", dirs_exist_ok=True)

        temp_dir = f"{TEMP}/lazygit"
        fname = install_tar_gz(LAZYGIT_URL, temp_dir)
        shutil.copy(f"{temp_dir}/lazygit", f"{DEFAULT_DST}/bin")

        # Add completion script for zsh
        match shell:
            case "zsh":
                write_to_config_file(
                    ["source <(rg --generate complete-zsh)", "source <(fzf --zsh)"],
                    os.path.expanduser("~/.zshrc"),
                )

            case "bash":
                _dir = os.environ.get("XDG_CONFIG_HOME", "")
                _dir = os.path.join(_dir, "bash_completion")
                os.makedirs(_dir, exist_ok=True)
                _target = os.path.join(_dir, "rg.bash")
                subprocess.run(
                    [
                        f"{DEFAULT_DST}/bin/rg",
                        "--generate",
                        "complete-bash",
                        ">",
                        _target,
                    ],
                )

                write_to_config_file(
                    ["source <(fzf --bash)"], os.path.expanduser("~/.bashrc")
                )
            case "fish":
                _dir = os.environ.get("XDG_CONFIG_HOME", "")
                _dir = os.path.join(_dir, "fish", "completions")
                os.makedirs(_dir, exist_ok=True)
                _target = os.path.join(_dir, "rg.fish")
                subprocess.run(
                    [
                        f"{DEFAULT_DST}/bin/rg",
                        "--generate",
                        "complete-fish",
                        ">",
                        _target,
                    ],
                )
                subprocess.run(["fzf", "--fish", "|", "source"])
            case _:
                print(f"Unsupported shell: {shell}. No completion script added.")
    except ValueError as e:
        print(f"Failed to download: {e}")


def main() -> None:
    try:
        run("zsh")
    finally:
        shutil.rmtree(TEMP)


if __name__ == "__main__":
    main()
