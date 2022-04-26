"use strict";

module.exports = {
  purge: [
    "src/**/*.purs",
    process.env.WEB_COMMON_SRC + "/**/*.purs",
    process.env.WEB_COMMON_MARLOWE_SRC + "/**/*.purs",
  ],
  darkMode: false, // or 'media' or 'class'
  theme: {
    // TODO make a proper color scheme with shades and hues (like I've done for
    // gray here).
    colors: {
      "gray-100": "#f2f2f2",
      "gray-200": "#eeeeee",
      "gray-300": "#dfdfdf",
      "gray-400": "#d2d2d2",
      "gray-500": "#c4c4c4",
      "gray-600": "#b7b7b7",
      "gray-700": "#adadad",
      "gray-800": "#a4a4a4",
      "gray-900": "#9a9a9a",
      transparent: "transparent",
      current: "currentColor",
      black: "#283346",
      lightgray: "#eeeeee",
      gray: "#f2f2f2",
      green: "#00a551",
      lightgreen: "#00e872",
      darkgray: "#b7b7b7",
      overlay: "rgba(10,10,10,0.4)",
      white: "#ffffff",
      purple: "#4700c3",
      lightpurple: "#8701fc",
      grayblue: "#f5f9fc",
      red: "#e04b4c",
    },
    fontSize: {
      xxs: "9px",
      xs: "12px",
      sm: "14px",
      base: "16px",
      lg: "18px",
      xl: "24px",
      /* this value was requested for some icons in the contract home */
      "28px": "28px",
      "2xl": "34px",
      "3xl": "46px",
      "4xl": "64px",
      "big-icon": "100px",
      "medium-icon": "80px",
    },
    scale: {
      77: ".77",
    },
    borderRadius: {
      none: "0",
      xs: "2.5px",
      sm: "5px",
      DEFAULT: "10px",
      lg: "25px",
      full: "9999px",
    },
    dropShadow: {
      DEFAULT: [
        "0 5px 5px rgba(0, 0, 0, 0.15)",
        "5px 5px 5px rgba(0, 0, 0, 0.06)",
      ],
      lg: ["0 10px 5px rgba(0, 0, 0, 0.2)", "5px 10px 5px rgba(0, 0, 0, 0.04)"],
    },
    boxShadow: {
      none: "none",
      sm: "0 4px 6px -1px rgba(0,0,0,0.1), 0 2px 4px -1px rgba(0,0,0,0.06)",
      DEFAULT:
        "0 10px 15px -3px rgba(0,0,0,0.1), 0 4px 6px -2px rgba(0,0,0,0.05)",
      lg: "0 20px 25px -5px rgba(0,0,0,0.2), 0 10px 10px -5px rgba(0,0,0,0.04)",
      xl: "0 25px 50px -12px rgba(0,0,0,0.25)",
      deep: "0 2.5px 5px 0 rgba(0, 0, 0, 0.22)",
      flat: "0 0 20px 0 rgba(0, 0, 0, 0.3)",
    },
    extend: {
      animation: {
        "from-below": "from-below 250ms ease-out 1",
        "to-bottom": "to-bottom 250ms ease-out 1",
        grow: "grow 1s ease-in-out infinite",
      },
      transitionProperty: {
        width: "width",
      },
      backgroundImage: (theme) => ({
        "background-shape": "url('/static/images/background-shape.svg')",
        "get-started-thumbnail":
          "url('/static/images/get-started-thumbnail.jpg')",
        "link-highlight": "url('/static/images/link-highlight.svg')",
      }),
      keyframes: {
        "from-below": {
          "0%": { transform: "translateY(20px)", opacity: 0 },
          "100%": { transform: "translateY(0px)", opacity: 1 },
        },
        "to-bottom": {
          "0%": { transform: "translateY(0px)", opacity: 1 },
          "100%": { transform: "translateY(20px)", opacity: 0 },
        },
        grow: {
          "0%, 100%": { transform: "scale(1)" },
          "50%": { transform: "scale(1.15)" },
        },
      },
      gridTemplateRows: {
        "auto-1fr": "auto minmax(0, 1fr)",
        "1fr-auto": "minmax(0, 1fr) auto",
        "auto-auto-1fr": "auto auto minmax(0, 1fr)",
        "auto-auto-1fr-auto": "auto auto minmax(0, 1fr) auto",
        "auto-1fr-auto": "auto minmax(0, 1fr) auto",
        "auto-1fr-auto-auto": "auto minmax(0, 1fr) auto auto",
        "1fr-auto-1fr": "minmax(0, 1fr) auto minmax(0, 1fr)",
        "1fr-auto-auto-1fr": "minmax(0, 1fr) auto auto minmax(0, 1fr)",
        "1fr-auto-auto-1fr": "minmax(0, 1fr) auto auto minmax(0, 1fr)",
      },
      gridTemplateColumns: {
        "auto-1fr": "auto minmax(0, 1fr)",
        "1fr-auto": "minmax(0, 1fr) auto",
        "auto-auto-1fr": "auto auto minmax(0, 1fr)",
        "auto-1fr-auto": "auto minmax(0, 1fr) auto",
        "1fr-auto-1fr": "minmax(0, 1fr) auto minmax(0, 1fr)",
        "1fr-auto-auto-1fr": "minmax(0, 1fr) auto auto minmax(0, 1fr)",
      },
      spacing: {
        "2+2px": "calc(0.5rem + 2px)",
        4.5: "1.125rem",
        22: "5.5rem",
        160: "40rem",
        256: "64rem",
        "16:9": "56.25%", // this is used for video containers to maintain a 16:9 aspect ratio
        sidebar: "350px",
      },
      width: {
        sm: "375px",
        md: "640px",
        lg: "768px",
        "welcome-box": "400px",
        sidebar: "350px",
        "contracts-grid-md": "632px", // 2 cards of 300px + 1 gap of 32px
        "contracts-grid-lg": "964px", // 3 cards of 300px + 2 gaps of 32px
        "contract-card": "264px",
        /* This width is used by a padding element in both sides of the carousel and is enough
           to push the first and last card to the center */
        "carousel-padding-element": "calc(50% - 264px / 2)",
      },
      height: {
        "welcome-box": "227px",
        "dashboard-card-actions": "200px",
        "contract-card": "415px",
        "90pc": "90%",
      },
      borderWidth: {
        half: "0.5px",
      },
      maxWidth: {
        sm: "375px",
        md: "640px",
        lg: "768px",
        xl: "1440px",
        "contracts-grid-sm": "300px", // 1 card of 300px
        "90pc": "90%",
      },
      minWidth: {
        button: "120px",
        "90pc": "90%",
        sm: "375px",
        hint: "270px",
      },
    },
  },
  variants: {
    extend: {
      // note 'disabled' goes last so that it takes priority
      backgroundColor: ["last", "hover", "disabled"],
      backgroundImage: ["hover", "disabled"],
      boxShadow: ["hover", "disabled", "active"],
      cursor: ["hover", "disabled"],
      // This causes an error
      // spacing: ['first', 'last'],
      textColor: ["hover", "disabled"],
      margin: ["first", "last"],
      borderRadius: ["responsive"],
      padding: ["hover", "focus-within"],
    },
  },
  plugins: [require("@tailwindcss/forms")],
  corePlugins: {
    container: false,
    space: true,
    divideWidth: true,
    divideColor: true,
    divideStyle: false,
    divideOpacity: false,
    dropShadow: true,
    accessibility: false,
    appearance: false,
    backgroundAttachment: false,
    backgroundClip: false,
    backgroundColor: true,
    backgroundImage: true,
    gradientColorStops: true,
    backgroundOpacity: false,
    backgroundPosition: true,
    backgroundRepeat: true,
    backgroundSize: true,
    borderCollapse: false,
    borderColor: true,
    borderOpacity: false,
    borderRadius: true,
    borderStyle: true,
    borderWidth: true,
    boxSizing: false,
    cursor: true,
    display: true,
    flexDirection: true,
    flexWrap: false,
    placeItems: false,
    placeContent: false,
    placeSelf: false,
    alignItems: true,
    alignContent: true,
    alignSelf: true,
    justifyItems: false,
    justifyContent: true,
    justifySelf: true,
    flex: true,
    flexGrow: true,
    flexShrink: true,
    order: false,
    float: true,
    clear: false,
    fontFamily: true,
    fontWeight: true,
    height: true,
    lineHeight: true,
    listStylePosition: false,
    listStyleType: false,
    maxHeight: true,
    maxWidth: true,
    minHeight: false,
    minWidth: true,
    objectFit: false,
    objectPosition: false,
    opacity: true,
    outline: true,
    overflow: true,
    overscrollBehavior: false,
    placeholderColor: false,
    placeholderOpacity: false,
    pointerEvents: true,
    position: true,
    inset: true,
    resize: false,
    boxShadow: true,
    ringWidth: true,
    ringOffsetColor: false,
    ringOffsetWidth: false,
    ringColor: true,
    ringOpacity: false,
    fill: false,
    filter: true,
    stroke: false,
    strokeWidth: false,
    tableLayout: false,
    textAlign: true,
    textOpacity: true,
    textOverflow: true,
    fontStyle: true,
    textTransform: true,
    textDecoration: true,
    fontSmoothing: false,
    fontVariantNumeric: false,
    letterSpacing: false,
    userSelect: true,
    verticalAlign: false,
    visibility: true,
    whitespace: true,
    wordBreak: false,
    width: true,
    zIndex: true,
    gap: true,
    gridAutoFlow: false,
    gridTemplateColumns: true,
    gridAutoColumns: false,
    gridColumn: false,
    gridColumnStart: true,
    gridColumnEnd: false,
    gridTemplateRows: true,
    gridAutoRows: true,
    gridRow: false,
    gridRowStart: true,
    gridRowEnd: false,
    transform: true,
    transformOrigin: true,
    scale: true,
    rotate: true,
    translate: true,
    skew: false,
    transitionProperty: true,
    transitionTimingFunction: true,
    transitionDuration: true,
    transitionDelay: false,
    animation: true,
  },
};
