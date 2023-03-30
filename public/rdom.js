const ELEMENT_NAME = "rdom-embed";
const DEFAULT_ENDPOINT = "/.rdom";
const SESSION_ID_HEADER = "x-rdom-session-id";
const STREAM_MIME_TYPE = "x-rdom/json-stream";
const CONNECTED_STATE = "--connected"
const CONNECTED_CLASS = "--rdom-connected"

const STYLESHEETS = {
  root: createStylesheet(`
    :host {
      display: flow-root;
      box-sizing: border-box;
    }
    *:not(:defined) {
      /* Hide elements until they are fully loaded */
      display: none;
    }
  `),
  customElement: createStylesheet(`
    :host {
      display: contents;
    }
  `),
  boxSizing: createStylesheet(`
    *, *::before, *::after {
      box-sizing: border-box;
    }
  `),
}

customElements.define(
  ELEMENT_NAME,
  class VDOMRoot extends HTMLElement {
    #internals

    constructor() {
      super();
      this.attachShadow({ mode: "open" });
      this.#internals = this.attachInternals();
      this.#setConnectedState(false);

      this.shadowRoot.adoptedStyleSheets = [
        STYLESHEETS.root,
        STYLESHEETS.boxSizing,
      ];
    }

    async connectedCallback() {
      try {
        const endpoint = this.getAttribute("src") || DEFAULT_ENDPOINT;
        const res = await connect(endpoint);

        const output = initCallbackStream(endpoint, getSessionIdHeader(res));

        this.#setConnectedState(true);

        await res.body
          .pipeThrough(new TextDecoderStream())
          .pipeThrough(new JSONDecoderStream())
          .pipeThrough(new PatchStream(endpoint, this.shadowRoot))
          .pipeThrough(new JSONEncoderStream())
          .pipeThrough(new TextEncoderStream())
          .pipeTo(output);
      } finally {
        console.error("🔴 Disconnected!");
        this.#setConnectedState(false);
      }
    }

    #setConnectedState(isConnected) {
      if (isConnected) {
        this.#internals.states?.add(CONNECTED_STATE);
        this.classList.add(CONNECTED_CLASS);
      } else {
        this.#internals.states?.delete(CONNECTED_STATE);
        this.classList.remove(CONNECTED_CLASS);
      }
    }
  }
);

function getSessionIdHeader(res) {
  const sessionId = res.headers.get(SESSION_ID_HEADER);
  if (sessionId) return sessionId;
  throw new Error(`Could not read header: ${SESSION_ID_HEADER}`);
}

async function connect(endpoint) {
  console.info("🟡 Connecting to", endpoint);

  const res = await fetch(endpoint, {
    method: "GET",
    mode: "cors",
    headers: new Headers({ accept: STREAM_MIME_TYPE }),
  });

  if (!res.ok) {
    alert("Connection failed!");
    console.error(res);
    throw new Error("Res was not ok.");
  }

  const contentType = res.headers.get("content-type");

  if (contentType !== STREAM_MIME_TYPE) {
    alert(`Unexpected content type: ${contentType}`);
    console.error(res);
    throw new Error(`Unexpected content type: ${contentType}`);
  }

  console.info("🟢 Connected to", endpoint);

  return res;
}

class JSONDecoderStream extends TransformStream {
  constructor() {
    // This transformer is based on this code:
    // https://rob-blackbourn.medium.com/beyond-eventsource-streaming-fetch-with-readablestream-5765c7de21a1#6c5e
    super({
      start(controller) {
        controller.buf = "";
        controller.pos = 0;
      },

      transform(chunk, controller) {
        controller.buf += chunk;

        while (controller.pos < controller.buf.length) {
          if (controller.buf[controller.pos] === "\n") {
            const line = controller.buf.substring(0, controller.pos);
            controller.enqueue(JSON.parse(line));
            controller.buf = controller.buf.substring(controller.pos + 1);
            controller.pos = 0;
          } else {
            controller.pos++;
          }
        }
      },
    });
  }
}

class JSONEncoderStream extends TransformStream {
  constructor() {
    super({
      transform(chunk, controller) {
        controller.enqueue(JSON.stringify(chunk) + "\n");
      },
    });
  }
}

const supportsRequestStreams = (() => {
  // https://developer.chrome.com/articles/fetch-streaming-requests/#feature-detection
  let duplexAccessed = false;

  const hasContentType = new Request("", {
    body: new ReadableStream(),
    method: "POST",
    get duplex() {
      duplexAccessed = true;
      return "half";
    },
  }).headers.has("Content-Type");

  return duplexAccessed && !hasContentType;
})();

function initCallbackStream(endpoint, sessionId) {
  if (!supportsRequestStreams) {
    return initCallbackStreamFetchFallback(endpoint, sessionId);
  }

  const { readable, writable } = new TransformStream();

  fetch(endpoint, {
    method: "POST",
    headers: {
      "content-type": STREAM_MIME_TYPE,
      [SESSION_ID_HEADER]: sessionId,
    },
    duplex: "half",
    mode: "cors",
    body: readable,
  });

  return writable;
}

function initCallbackStreamFetchFallback(endpoint, sessionId) {
  return new WritableStream({
    write(body, controller) {
      fetch(endpoint, {
        method: "POST",
        headers: new Headers({
          "content-type": "application/json",
          [SESSION_ID_HEADER]: sessionId,
        }),
        mode: "cors",
        body: body,
      });
    },
  });
}

class RAFQueue {
  constructor(onFlush) {
    this.onFlush = onFlush;
    this.queue = [];
    this.raf = null;
  }

  enqueue(msg) {
    this.queue.push(msg);
    this.raf ||= requestAnimationFrame(() => this.flush());
  }

  flush() {
    this.raf = null;
    const queue = this.queue;
    if (queue.length === 0) return;
    this.queue = [];
    this.onFlush(queue);
  }
}

class PatchStream extends TransformStream {
  constructor(endpoint, root) {
    super({
      start(controller) {
        controller.endpoint = endpoint;
        controller.root = root;
        controller.nodes = new Map();
        controller.navigationPromise = null;

        controller.rafQueue = new RAFQueue(async (patches) => {
          console.debug("Applying", patches.length, "patches");
          console.time("patch");

          for (const patch of patches) {
            const [type, ...args] = patch;

            const patchFn = PatchFunctions[type];

            if (!patchFn) {
              console.error("Patch not implemented:", type);
              continue;
            }

            try {
              await patchFn.apply(controller, args);
            } catch (e) {
              console.error(e);
            }
          }

          console.timeEnd("patch");
        });
      },
      transform(patch, controller) {
        controller.rafQueue.enqueue(patch);
      },
      flush(controller) {},
    });
  }
}

function startViewTransition() {
  if (!document.startViewTransition) {
    return Promise.resolve();
  }

  return new Promise((resolve) => {
    document.startViewTransition(() => resolve());
  });
}

function setupNavigationListener(controller) {
  navigation.addEventListener("navigate", (e) => {
    console.log(e);

    if (!e.canIntercept || e.hashChange) {
      return;
    }

    controller.navigationPromise ||= new Promise();

    e.intercept({
      async handler() {
        e.signal.addEventListener("abort", () => {
          promise.reject();
          controller.navigationPromise = null;
        });

        await promise;
        controller.navigationPromise = null;
      },
    });
  });
}

const PatchFunctions = {
  Event(name, payload = {}) {
    console.warn("Event", name, payload);

    switch (name) {
      case "startViewTransition": {
        return startViewTransition();
      }
      default: {
        break;
      }
    }
  },
  CreateRoot() {
    const root = document.createElement("rdom-root");
    this.nodes.set(null, root);
    this.root.appendChild(root);
    // setupNavigationListener(this)
  },
  DestroyRoot() {
    const root = this.nodes.get(null);
    if (!root) return;
    this.nodes.delete(null);
    root.remove();
  },
  CreateElement(id, type) {
    this.nodes.set(id, document.createElement(type));
  },
  InsertBefore(parentId, id, refId) {
    const parent = this.nodes.get(parentId);
    const child = this.nodes.get(id);
    const ref = refId && this.nodes.get(refId);
    parent.insertBefore(child, ref);
  },
  RemoveChild(parentId, id) {
    const child = this.nodes.get(id);
    if (!child) return;

    const parent = this.nodes.get(parentId);
    if (!parent) return;

    if (child.parent == parent) {
      parent.removeChild(child);
    }
  },
  RemoveNode(id) {
    const node = this.nodes.get(id);
    if (!node) return;
    if (node.remove) {
      node.remove();
    }
    this.nodes.delete(id);
  },
  DefineCustomElement(name, filename) {
    RDOMElement.fetchAndDefine(
      name,
      new URL(`${this.endpoint}/${filename}`, import.meta.url)
    );
  },
  AssignSlot(id, name, ids) {
    const node = this.nodes.get(id);
    if (!node) return;
    customElements.whenDefined(node.localName).then(() => {
      node.assignSlot(
        name,
        ids.map((id) => this.nodes.get(id)).filter(Boolean)
      );
    });
  },
  CreateTextNode(id, content) {
    this.nodes.set(id, document.createTextNode(content));
  },
  SetTextContent(id, content) {
    this.nodes.get(id).textContent = content;
  },
  ReplaceData(id, offset, count, data) {
    this.nodes.get(id).replaceData(offset, count, data);
  },
  InsertData(id, offset, data) {
    this.nodes.get(id).insertData(offset, data);
  },
  DeleteData(id, offset, count) {
    this.nodes.get(id).deleteData(offset, count);
  },
  SetAttribute(parentId, refId, name, value) {
    const parent = this.nodes.get(parentId);
    if (!parent) return;
    customElements.whenDefined(parent.localName).then(() => {
      const node = parent.shadowRoot?.getElementById(refId);
      if (!node) return;

      if (node instanceof HTMLInputElement) {
        switch (name) {
          case "value": {
            node.value = value;
            break;
          }
          case "checked": {
            node.checked = true;
            break;
          }
          case "indeterminate": {
            node.indeterminate = true;
            break;
          }
        }
      }

      if (name === "initial-value") {
        name = "value";
      } else {
        name = name.replaceAll("_", "");
      }

      node.setAttribute(name, value);
    });
  },
  RemoveAttribute(parentId, refId, name) {
    const parent = this.nodes.get(parentId);
    if (!parent) return;
    const node = parent.shadowRoot?.getElementById(refId);
    node?.removeAttribute(name);
  },
  CreateDocumentFragment(id) {
    this.nodes.set(id, document.createDocumentFragment());
  },
  SetCSSProperty(parentId, refId, name, value) {
    const parent = this.nodes.get(parentId);
    if (!parent) return;
    customElements.whenDefined(parent.localName).then(() => {
      const node = parent.shadowRoot.getElementById(refId);
      if (!node) return;
      node.style.setProperty(name, value);
    });
  },
  RemoveCSSProperty(parentId, refId, name) {
    const parent = this.nodes.get(parentId);
    if (!parent) return;
    const node = parent.shadowRoot.getElementById(refId);
    if (!node) return;
    node.style.removeProperty(name);
  },
  SetHandler(parentId, refId, event, callbackId) {
    const parent = this.nodes.get(parentId);
    customElements.whenDefined(parent.localName).then(() => {
      const elem = parent.shadowRoot.getElementById(refId);

      this.nodes.set(
        callbackId,
        elem.addEventListener(event.replace(/^on/, ""), (e) => {
          e.preventDefault();

          const payload = {
            type: e.type,
            target: e.target && {
              value: e.target.value,
            },
          };

          this.enqueue(["callback", callbackId, payload]);
        })
      );
    });
  },
  RemoveHandler(parentId, refId, event, callbackId) {
    const parent = this.nodes.get(parentId);
    if (!parent) return;
    const elem = parent.shadowRoot?.getElementById(refId);

    elem?.removeEventListener(
      event.replace(/^on/, ""),
      this.nodes.get(callbackId)
    );
    this.nodes.delete(callbackId);
  },
  Ping(time) {
    this.enqueue(["pong", time]);
  },
};

class RDOMElement extends HTMLElement {
  static template = null;

  static async fetchAndDefine(name, url) {
    if (customElements.get(name)) return;
    const html = await fetchTemplate(url);
    const template = createTemplate(html, url);
    RDOMElement.define(name, template);
  }

  static define(name, template) {
    if (customElements.get(name)) return;

    customElements.define(
      name,
      class extends RDOMElement {
        static template = template;
      }
    );
  }

  connectedCallback() {
    this.attachShadow({
      mode: "open",
      slotAssignment: "manual",
    });

    const { template, stylesheet } = this.constructor;

    this.shadowRoot.appendChild(
      template.content.cloneNode(true)
    );

    this.shadowRoot.adoptedStyleSheets = [
      STYLESHEETS.customElement,
      STYLESHEETS.boxSizing,
    ];
  }

  assignSlot(name, nodes) {
    const slot = this.shadowRoot.getElementById(name);
    if (!slot) {
      throw new Error(`No slot with name ${name}`);
    }
    slot.assign(...nodes);
  }
}

function createStylesheet(source) {
  const styles = new CSSStyleSheet();
  styles.replace(source)
  return styles;
}

async function fetchTemplate(url) {
  const res = await fetch(url, {
    headers: new Headers({ accept: "text/html" }),
  });
  return res.text();
}

function createTemplate(html, baseUrl) {
  const template = document
    .createRange()
    .createContextualFragment(`<template>${html}</template>`).firstElementChild;
  for (const link of template.content.querySelectorAll("link")) {
    link.setAttribute("href", new URL(link.getAttribute("href"), baseUrl));
  }
  return template;
}
