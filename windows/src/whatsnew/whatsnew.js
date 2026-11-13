function el(tag, text) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text; // textContent: the changelog is data, not markup
  return node;
}

window.whatsNewApi.entries().then((entries) => {
  const content = document.getElementById("content");
  content.append(el("h1", "What's new"));
  for (const entry of entries) {
    content.append(el("h2", `Version ${entry.version}`));
    const list = el("ul");
    for (const line of entry.lines) list.append(el("li", line));
    content.append(list);
    if (entry.imageData) {
      const img = document.createElement("img");
      img.src = entry.imageData;
      img.alt = "";
      content.append(img);
    }
  }
});
