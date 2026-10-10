# Third-party notices

The integrated target contains or links code from these upstream projects:

- **LocalDevVPN / StosVPN** — local packet-tunnel provider, CIDR validation, and tunnel constants derived from seomin0610/LocalDevVPN at `8a97427bcbdf90cbb62c2eadb8cfe5751c50eccc`. Original authors include Stossy11, Magesh K, and the SideStore Team. The complete StosVPN license is in `SideKickVPN/LICENSE`; provenance and modifications are in `SideKickVPN/UPSTREAM.md`.

- **SideStore** — GNU Affero General Public License v3.0. License text is in `Vendor/SideStore/LICENSE`.
- **Minimuxer** — GNU Affero General Public License v3.0. License text is in `Vendor/SideStore/Dependencies/minimuxer/LICENSE`.
- **SideSign** — upstream repository is identified as GNU General Public License v3.0: <https://github.com/SideStore/SideSign>. The pinned submodule revision currently has no root `LICENSE` file, so its license text must be included here or in the distribution bundle before distributing the integrated app.

SideStore's Xcode project resolves additional Swift packages. Their exact resolved revisions are preserved in the project files, but their individual license texts have not yet been audited for a release bundle. Keep their notices with any corresponding-source package.

Every distributed binary must be accompanied by the corresponding source for that exact build, including the pinned submodules and SideKick integration patch. An unsigned CI artifact is not a release-ready or device-verified binary.
