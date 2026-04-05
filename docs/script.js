const nodes = document.querySelectorAll('.reveal');

const observer = new IntersectionObserver(
  (entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
      }
    }
  },
  {
    threshold: 0.12,
    rootMargin: '0px 0px -30px 0px'
  }
);

nodes.forEach((node, index) => {
  node.style.transitionDelay = `${Math.min(index * 70, 350)}ms`;
  observer.observe(node);
});
