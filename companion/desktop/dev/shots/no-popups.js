// shoot.sh eval: links the page would hand to the shell (a Gmail draft, a meeting) open nothing in the headless
// browser, so a shot after a click stays on the page.
window.open = () => null;
