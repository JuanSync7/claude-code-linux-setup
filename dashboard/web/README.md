# web/

| File | What it is |
| --- | --- |
| `index.html` | The shell: sidebar of pages, empty main pane |
| `app.js` | Fetches the API and builds each page; every value goes in as text, never HTML |
| `style.css` | The whole visual system: palette, type, layout |
| `favicon.svg` | The mark |

The server's Content-Security-Policy is `default-src 'self'`: no inline script or
style, and no font or script from another origin.
