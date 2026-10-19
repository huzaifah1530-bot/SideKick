# Next Update

**Started:** 19 October 2026  
**Status:** Collecting bugs

This is the rolling bug and fix list for the next SideKick update. Add each newly reported issue under **Reported bugs**, keeping the user's wording where possible. Move items to **Completed** once fixed and verified.

## Reported bugs

### Anisette server refresh and recovery

- **Type:** Feature / reliability improvement (not a confirmed bug)
- **Area:** Settings → Advanced → Anisette
- The current option is called **Use Windows Anisette server**. Rename it to something that describes its purpose, such as **Use newest Anisette server** or another clear label. The option should let a user switch to the currently recommended server when the one they are using has been patched or stopped working.
- When the user taps the option/action, SideKick should check the project's GitHub repository source code, not GitHub Releases. The repository should contain a designated configuration file listing the available/recommended server information, including the server URL (HTTPS or equivalent) and any custom HTTP headers required to use it.
- SideKick should fetch the values from that file and apply them as the Anisette server configuration. This lets the project maintainer replace a server in the repository when an older server gets patched, so users can try the replacement without waiting for an app release.
- Show the date/time that the configuration file was last updated somewhere on the same Settings page, so users can tell whether the server list was updated recently or has not yet been fixed.
- If SideKick reports an error caused by Anisette, prompt the user to go to Settings and try the server refresh/switch action, in case a newer server configuration is available.
- **Open detail:** Choose the final setting/action label and the exact GitHub repository path and configuration-file format during implementation.

### Support multiple LiveContainer installations and shared apps

- **Type:** Feature / missing app discovery
- SideKick currently supports only one LiveContainer app. A user may have two or three LiveContainer installations, and SideKick should discover and support apps from all of them.
- SideKick should also discover and support apps that LiveContainer itself marks or exposes as shared apps. They should not disappear simply because they use LiveContainer's sharing arrangement.
- Account for the different folders or storage locations used by each LiveContainer installation and by shared apps, so the correct apps can be found and managed.
- On the Home screen, keep every discovered LiveContainer app together under the existing single **LiveContainer** section. Do not create a separate visible section for each installation.

### Fix the LiveContainer update controls and confirmation sheet

- **Type:** UI bug
- **Area:** Updating an app inside LiveContainer
- The controls for actions such as **Install**, **Download**, and **Share** currently appear to float over the interface instead of sitting within the app page. Place them as part of the page layout so they remain readable and do not obscure other content.
- After a download, the confirmation sheet asking whether the update installed opens only about halfway. Part of it sits behind the page controls, so the user has to drag it upward to read and use it. Open this sheet fully expanded from the start.

### Make LiveContainer app pages match regular app pages

- **Type:** UI consistency improvement
- **Area:** App detail pages, including the pages reached while browsing GitHub updates
- LiveContainer app detail pages currently use a different interface from regular app detail pages. Make the LiveContainer pages look and behave the same as the regular app pages throughout the page flow.
- Keep the regular app pages as the reference. This request concerns the pages opened for an app, not its presentation on the Home screen.
- If a LiveContainer app needs an action or setting that a regular app does not, put it in the **three-dot menu at the top right** rather than changing the main page layout.

## Completed

_None yet._


