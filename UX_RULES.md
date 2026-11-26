# Mobile UX Rules

## iOS journal header

Journal and page content scrolls beneath the navigation bar and status area. Keep the navigation bar background transparent across scroll positions. Use the native soft top scroll-edge effect for the frosted fade on horizontal headers, and keep Liquid Glass on the individual controls. The page theme fills the underlying surface continuously across the top safe area.

Configure the bar background and scroll-edge effect on the navigation surface. Search presentation, selection, and editor state can change independently of the header. A full-width color or material on the navigation bar or top safe area produces a visible band, especially in Solarized dark mode.

For changes to navigation or safe areas, scroll both text and an image under the header in light and Solarized dark modes. Check the top of the list, the scrolled state, and the return from search or selection. The content should remain visible through a gradual blur, without a horizontal seam at the edge of the bar.

Pushed pages use the native Back control with its own circular Liquid Glass and an adaptive foreground. Scope the app accent to page content and actions so the navigation bar can choose its own contrast. Check Back at the top of the page and after scrolling, both when opening from Journals and from search results. Verify that tapping Back and swiping from the leading edge return to the previous page.

## Journal Add block placeholder

Each journal page owns its Add block placeholder. A regular inline editor hides the Add block control on its own page. Other dates keep their controls available, including empty journal pages. Editing a math or code block keeps the Add block control available on that page.

On iOS and Android, the Today and Upcoming task queries appear in the Tasks tab.

## iOS journal keyboard

Reveal the caret just enough to clear the keyboard and editor toolbar. When the toolbar dismisses the keyboard, keep the edited block at its pre-dismissal screen position throughout the transition. The floating editor toolbar guides caret avoidance, and showing or hiding it keeps the scroll viewport the same size. Check the middle and end of a long journal with task blocks and image assets, including reopening the same block.
