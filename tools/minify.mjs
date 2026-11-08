// Shrinks the built index.html (comments, spaces, long local names). Used by build.sh: node tools/minify.mjs index.html index.html
import { minify } from 'html-minifier-terser';
import fs from 'fs';
const [,, inp, out, keep] = process.argv;
const src = fs.readFileSync(inp, 'utf8');
const res = await minify(src, {
  removeComments: true, ignoreCustomComments: keep ? [/^ r10:/] : [],
  collapseWhitespace: true, conservativeCollapse: true,
  minifyCSS: true,
  minifyJS: { compress: { passes: 1, keep_fargs: true, keep_fnames: true, keep_classnames: true, unsafe: false, pure_getters: false, reduce_funcs: false }, mangle: { keep_fnames: true, keep_classnames: true }, format: { comments: false } },
  keepClosingSlash: true, caseSensitive: true,
});
fs.writeFileSync(out, res);
console.log(src.length, '→', res.length, 'gzip', (await import('zlib')).gzipSync(src).length, '→', (await import('zlib')).gzipSync(res).length);
