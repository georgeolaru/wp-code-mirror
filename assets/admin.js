document.addEventListener('DOMContentLoaded', () => {
  const targetsRoot = document.querySelector('[data-targets-root]');
  const addButton = document.querySelector('[data-add-target]');
  const template = document.getElementById('wp-code-mirror-target-template');

  if (!targetsRoot || !addButton || !template) {
    return;
  }

  const refreshIndexes = () => {
    const targets = Array.from(targetsRoot.querySelectorAll('[data-target]'));
    targets.forEach((target, index) => {
      const fields = target.querySelectorAll('input[name], textarea[name]');
      fields.forEach((field) => {
        field.name = field.name.replace(/targets\[[^\]]+\]/, `targets[${index}]`);
      });
    });
  };

  addButton.addEventListener('click', () => {
    const html = template.innerHTML.replace(/__INDEX__/g, String(Date.now()));
    targetsRoot.insertAdjacentHTML('beforeend', html);
    refreshIndexes();
  });

  targetsRoot.addEventListener('click', (event) => {
    const button = event.target.closest('[data-remove-target]');
    if (!button) {
      return;
    }

    const card = button.closest('[data-target]');
    if (!card) {
      return;
    }

    card.remove();
    refreshIndexes();
  });
});
