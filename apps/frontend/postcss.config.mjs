/** @type {import('postcss-load-config').Config} */
const config = {
  plugins: {
    // Tailwind CSS v4 는 PostCSS 플러그인을 별도 패키지로 분리했다.
    "@tailwindcss/postcss": {},
  },
};

export default config;
