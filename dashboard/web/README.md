# web/

| File | What it is |
| --- | --- |
| `index.html` | The shell: sidebar of pages, empty main pane |
| `app.js` | Takes the login token from the address, fetches the API with it and builds each page, including the Markdown reader for Docs; every value goes in as text, never HTML |
| `style.css` | The whole visual system: palette, type, layout |
| `favicon.svg` | The mark |

The server's Content-Security-Policy is `default-src 'self'`: no inline script or
style, and no font or script from another origin.
