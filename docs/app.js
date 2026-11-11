(() => {
  const SAMPLES = {
    raw: [
      {
        app: 'Telegram, повідомлення',
        latency: 'Вставка: 240 мс (Parakeet v3)',
        speed: 'Швидкість: 142 сл/хв',
        saved: 'У 3,5 раза швидше за клавіатуру',
        live: 'Привіт надішли будь ласка фінальний монтаж у телеграм…',
        final: "Привіт! Надішли, будь ласка, фінальний монтаж у Telegram і лінк на GitHub до п'ятої вечора."
      },
      {
        app: 'Нотатки, ідеї проєкту',
        latency: 'Вставка: 215 мс (Parakeet v3)',
        speed: 'Швидкість: 156 сл/хв',
        saved: 'Зекономлено 18 секунд на одній фразі',
        live: 'Запиши короткий план релізу спочатку перевіряємо звук на AirPods…',
        final: 'Запиши короткий план релізу: спочатку перевіряємо звук на AirPods, потім збираємо образ диска й публікуємо на GitHub.'
      }
    ],
    clean: [
      {
        app: 'Пошта, робочий лист',
        latency: 'Обробка: 490 мс (Чиста думка)',
        speed: 'Прибрано слова-паразити й обмовки',
        saved: 'Готово до відправлення без правок',
        live: 'Ну слухай давай мабуть перенесемо дзвінок не на вівторок а на середу о одинадцятій…',
        final: 'Перенесімо наш дзвінок на середу об 11:00, так ми встигнемо спокійно узгодити всі деталі макета.'
      }
    ],
    en: [
      {
        app: 'Slack, #product-design',
        latency: 'Переклад UA в EN: 520 мс',
        speed: 'Говориш українською, пише англійською',
        saved: 'Природна ділова англійська',
        live: 'Привіт команді я щойно оновив прототип у фігмі подивіться будь ласка…',
        final: 'Hey team, I just updated the Figma prototype. Please take a look before our afternoon sync.'
      }
    ]
  };

  let currentMode = 'raw';
  let sampleIdx = 0;
  let isRecording = false;
  let rafId = null;
  let startTs = 0;

  const hudBar = document.getElementById('hud-bar');
  const pttBtn = document.getElementById('ptt-btn');
  const timerEl = document.getElementById('hud-timer');
  const demoText = document.getElementById('demo-text');
  const demoApp = document.getElementById('demo-app-name');
  const demoLatency = document.getElementById('demo-latency');
  const demoSpeed = document.getElementById('demo-speed');
  const demoSaved = document.getElementById('demo-saved');
  const bars = Array.from(document.querySelectorAll('#waveform span'));

  function currentSample() {
    const list = SAMPLES[currentMode] || SAMPLES.raw;
    return list[sampleIdx % list.length];
  }

  function applySample(sample) {
    if (!sample) return;
    demoApp.textContent = sample.app;
    demoLatency.textContent = sample.latency;
    demoText.textContent = sample.final;
    demoSpeed.textContent = sample.speed;
    demoSaved.textContent = sample.saved;
  }

  function resetBars() {
    bars.forEach((bar, idx) => {
      const idle = 0.18 + ((idx * 7) % 5) * 0.04;
      bar.style.transform = `scaleY(${idle.toFixed(2)})`;
    });
  }

  function animateRecording(now) {
    if (!isRecording) return;
    const elapsed = (now - startTs) / 1000;
    const secs = Math.floor(elapsed);
    const tenths = Math.floor((elapsed - secs) * 10);
    timerEl.textContent = `0:0${Math.min(9, secs)}.${tenths}`;

    const sample = currentSample();
    const words = sample.live.split(' ');
    const shownCount = Math.max(2, Math.min(words.length, Math.floor(elapsed * 4.5) + 2));
    demoText.textContent = words.slice(0, shownCount).join(' ');

    bars.forEach((bar, i) => {
      const wave = Math.sin(now * 0.011 + i * 0.65) * 0.35 + Math.cos(now * 0.019 - i * 0.4) * 0.25;
      const scale = Math.max(0.18, Math.min(1, 0.48 + wave));
      bar.style.transform = `scaleY(${scale.toFixed(2)})`;
    });

    rafId = requestAnimationFrame(animateRecording);
  }

  function startDemoRecording() {
    if (isRecording) return;
    isRecording = true;
    startTs = performance.now();
    hudBar.dataset.recording = 'true';
    pttBtn.dataset.active = 'true';
    pttBtn.querySelector('span').textContent = 'Слухаю… Відпусти для вставки';
    demoLatency.textContent = 'Запис голосу (16 кГц)…';
    rafId = requestAnimationFrame(animateRecording);
  }

  function stopDemoRecording() {
    if (!isRecording) return;
    isRecording = false;
    if (rafId) cancelAnimationFrame(rafId);
    hudBar.dataset.recording = 'false';
    pttBtn.dataset.active = 'false';
    pttBtn.querySelector('span').textContent = '⌥ Тримати Option';
    timerEl.textContent = '0:00.0';
    resetBars();

    const sample = currentSample();
    applySample(sample);
    sampleIdx += 1;
  }

  resetBars();

  if (pttBtn) {
    pttBtn.addEventListener('pointerdown', (e) => {
      e.preventDefault();
      startDemoRecording();
    });
    window.addEventListener('pointerup', stopDemoRecording);
    window.addEventListener('pointercancel', stopDemoRecording);
  }

  window.addEventListener('keydown', (e) => {
    if (e.key === 'Alt' && !e.metaKey && !e.ctrlKey && !e.repeat) {
      startDemoRecording();
    } else if (isRecording && e.key !== 'Alt') {
      stopDemoRecording();
    }
  });

  window.addEventListener('keyup', (e) => {
    if (e.key === 'Alt') {
      stopDemoRecording();
    }
  });

  window.addEventListener('blur', stopDemoRecording);

  document.querySelectorAll('[data-demo-mode]').forEach((btn) => {
    btn.addEventListener('click', () => {
      currentMode = btn.dataset.demoMode;
      sampleIdx = 0;
      document.querySelectorAll('[data-demo-mode]').forEach((b) => {
        b.setAttribute('aria-selected', String(b === btn));
      });
      applySample(currentSample());
    });
  });

  document.querySelectorAll('[data-tour]').forEach((tab) => {
    tab.addEventListener('click', () => {
      const target = tab.dataset.tour;
      document.querySelectorAll('[data-tour]').forEach((t) => {
        t.setAttribute('aria-selected', String(t === tab));
      });
      ['stats', 'modes', 'vocab', 'history'].forEach((id) => {
        const pane = document.getElementById(`pane-${id}`);
        if (pane) pane.hidden = id !== target;
      });
    });
  });

  document.querySelectorAll('[data-copy]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const targetId = btn.dataset.copy;
      const codeEl = document.getElementById(targetId);
      if (!codeEl) return;
      try {
        await navigator.clipboard.writeText(codeEl.textContent.trim());
        const prev = btn.textContent;
        btn.textContent = 'Скопійовано';
        setTimeout(() => {
          btn.textContent = prev;
        }, 1600);
      } catch {}
    });
  });
})();
