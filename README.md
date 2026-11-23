# Leaf OS 3.0 ISO with internet

This kit builds `leafos-3.0-amd64.iso`, a bootable image for VirtualBox, USB sticks and real PCs.
It runs a small Debian 12 Linux underneath. Leaf OS opens full screen in a built-in Chromium
browser, so the internet features all work: web search, Reader view, YouTube, Weather, Maps,
Radio, News, currency rates and the speed test.

## Option A: build it on GitHub (free, no PC setup)

1. Create a new **public** repository on github.com, for example `leafos-iso`.
2. Upload everything in this folder, including the hidden `.github` folder.
   On a computer, drag the files into **Add file → Upload files**.
3. Open the **Actions** tab. If asked, click **I understand my workflows, enable them**.
   Then open **Build Leaf OS ISO** and click **Run workflow**.
4. After about 20–30 minutes, open **Releases** (on the right side of the repository page)
   and download `leafos-3.0-amd64.iso` (about 700 MB–1 GB).

## Option B: build it on your own computer

You need [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows, macOS or Linux).
Open a terminal in this folder and run:

```
docker run --rm --privileged -v "$PWD":/build -w /build debian:bookworm bash ./build.sh
```

On Windows PowerShell, use `${PWD}` instead of `"$PWD"`. The ISO appears in the `out` folder.

## Set up VirtualBox

1. **New** → Name: `Leaf OS` → ISO Image: choose `leafos-3.0-amd64.iso`
   → Type: **Linux**, Version: **Debian (64-bit)**. Tick **Skip Unattended Installation**.
2. Memory: **2048 MB** or more. Processors: **2**.
3. Hard disk: **Do Not Add a Virtual Hard Disk** (Leaf OS runs from the ISO).
4. Settings → Display: Graphics Controller **VMSVGA**, Video Memory **64 MB** or more.
5. Settings → Network: leave **NAT** turned on. This is what gives Leaf OS internet.
6. Settings → Audio: turned on (needed for Leaf Radio and YouTube).
7. **Start**. The boot menu picks Leaf OS automatically after 5 seconds. Leaf OS appears about 20–40 seconds later.

## Good to know

* **Saving:** this is a live system, so files, settings and bookmarks reset when the VM restarts.
* **Shut down:** use **Start → Shut down**, or type `shutdown` in the Leaf OS Terminal.
* **Keyboard and time zone:** set at the top of `build.sh` (`KEYBOARD="es"`, `TIMEZONE="Europe/Madrid"`).
  Change them before building if you use a different keyboard.
* **Screen size:** Leaf OS asks for 1280×800 (the `SCREEN` setting in `build.sh`). If the window is
  too small, choose View → Virtual Screen 1 → a bigger size in VirtualBox.
* **Real PC:** you can write the ISO to a USB stick with balenaEtcher or Rufus and boot from it.
