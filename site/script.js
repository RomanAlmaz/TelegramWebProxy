(() => {
  const CG = "https://api.coingecko.com/api/v3";
  const BN = "https://api.binance.com/api/v3";
  const FX = "https://open.er-api.com/v6/latest/USD";

  const TOP_LIMIT = 8;

  const ASSETS = [
    { id: "bitcoin", symbol: "BTC", name: "Bitcoin", pair: "BTCUSDT", tone: "#f7931a", usd: 63670, supply: 1.987e7, volume: 2.8e10, change: 0.35, image: "icons/bitcoin.png" },
    { id: "ethereum", symbol: "ETH", name: "Ethereum", pair: "ETHUSDT", tone: "#627eea", usd: 2485, supply: 1.204e8, volume: 1.5e10, change: 0.62, image: "icons/ethereum.png" },
    { id: "tether", symbol: "USDT", name: "Tether", pair: null, tone: "#26a17b", usd: 1, supply: 1.2e11, volume: 5.5e10, change: 0.01, image: "icons/tether.png" },
    { id: "binancecoin", symbol: "BNB", name: "BNB", pair: "BNBUSDT", tone: "#f3ba2f", usd: 610, supply: 1.45e8, volume: 1.8e9, change: -0.28, image: "icons/bnb.png" },
    { id: "solana", symbol: "SOL", name: "Solana", pair: "SOLUSDT", tone: "#14f195", usd: 148, supply: 4.7e8, volume: 3.2e9, change: 1.15, image: "icons/solana.png" },
    { id: "ripple", symbol: "XRP", name: "XRP", pair: "XRPUSDT", tone: "#00a2e8", usd: 0.62, supply: 5.6e10, volume: 1.4e9, change: -0.45, image: "icons/xrp.png" },
    { id: "usd-coin", symbol: "USDC", name: "USDC", pair: "USDCUSDT", tone: "#2775ca", usd: 1, supply: 3.5e10, volume: 6.5e9, change: 0.0, image: "icons/usdc.png" },
    { id: "the-open-network", symbol: "TON", name: "Toncoin", pair: "TONUSDT", tone: "#0098ea", usd: 5.4, supply: 2.5e9, volume: 2.1e8, change: 0.55, image: "icons/ton.png" },
  ];

  const els = {
    app: document.getElementById("app"),
    rail: document.getElementById("rail"),
    stageEmpty: document.getElementById("stage-empty"),
    stageBody: document.getElementById("stage-body"),
    mastMeta: document.getElementById("mast-meta"),
    watermark: document.getElementById("watermark"),
    chartSpin: document.getElementById("chart-spin"),
    chartLabel: document.getElementById("chart-label"),
    chartError: document.getElementById("chart-error"),
    skelChart: document.getElementById("skel-chart"),
    railToggle: document.getElementById("rail-toggle"),
    canvas: document.getElementById("price-chart"),
  };

  const metricNodes = Object.fromEntries(
    [...document.querySelectorAll(".metric")].map((node) => [node.dataset.key, node])
  );

  const state = {
    coins: [],
    selectedId: null,
    days: "1",
    chart: null,
    chartReq: 0,
    source: "demo",
    usdRub: 84,
    loading: true,
  };

  const money = (value, currency) => {
    if (value == null || Number.isNaN(Number(value))) return "-";
    return Number(value).toLocaleString("ru-RU", {
      style: "currency",
      currency,
      maximumFractionDigits: Number(value) < 1 ? 6 : 2,
    });
  };

  const compactMoney = (value, currency = "USD") => {
    if (value == null || Number.isNaN(Number(value))) return "-";
    const n = Number(value);
    const abs = Math.abs(n);
    const sign = currency === "USD" ? "$" : currency === "RUB" ? "₽" : "";
    const fmt = (x, d) =>
      x.toLocaleString("ru-RU", { minimumFractionDigits: d, maximumFractionDigits: d });
    if (abs >= 1e12) return `${sign}${fmt(n / 1e12, 2)}T`;
    if (abs >= 1e9) return `${sign}${fmt(n / 1e9, 2)}B`;
    if (abs >= 1e6) return `${sign}${fmt(n / 1e6, 2)}M`;
    if (abs >= 1e3) return `${sign}${fmt(n / 1e3, 2)}K`;
    return money(n, currency);
  };

  const pct = (value) => {
    if (value == null || Number.isNaN(Number(value))) return "-";
    const n = Number(value);
    const sign = n > 0 ? "+" : "";
    return `${sign}${n.toFixed(2)}%`;
  };

  function normalizeBoard(coins) {
    const byId = Object.fromEntries(coins.map((c) => [c.id, c]));
    return ASSETS.map((meta, i) => {
      const coin = byId[meta.id];
      if (!coin) return null;
      return { ...coin, rank: i + 1, tone: meta.tone || coin.tone };
    }).filter(Boolean);
  }

  function sourceTag() {
    return state.source === "live" || state.source === "exchange" ? "live" : "demo";
  }

  function tickClock() {
    if (!els.mastMeta) return;
    const time = new Date().toLocaleTimeString("ru-RU");
    if (state.loading) {
      els.mastMeta.textContent = `Загрузка рынков… · ${time}`;
      return;
    }
    const count = state.coins.length || TOP_LIMIT;
    els.mastMeta.textContent = `${count} рынков · ${sourceTag()} · ${time}`;
  }

  function showSkeleton() {
    state.loading = true;
    tickClock();
    els.rail.innerHTML = Array.from({ length: TOP_LIMIT }, () => `
      <div class="skel-coin" aria-hidden="true">
        <span class="skel-bar skel-rank"></span>
        <span class="skel-circle"></span>
        <span class="skel-lines">
          <span class="skel-bar"></span>
          <span class="skel-bar short"></span>
        </span>
      </div>
    `).join("");

    els.stageEmpty.classList.add("is-hidden");
    els.stageBody.classList.remove("is-hidden");
    document.querySelectorAll(".metric").forEach((node) => {
      node.classList.add("is-skel");
      const b = node.querySelector("b");
      if (b) b.textContent = "\u00a0";
    });
    if (els.watermark) els.watermark.textContent = "";
    if (els.skelChart) els.skelChart.classList.remove("is-hidden");
    if (els.canvas) els.canvas.style.opacity = "0";
  }

  function hideSkeleton(opts = {}) {
    state.loading = false;
    document.querySelectorAll(".metric").forEach((node) => node.classList.remove("is-skel"));
    if (!opts.keepChartSkel) {
      if (els.skelChart) els.skelChart.classList.add("is-hidden");
      if (els.canvas) els.canvas.style.opacity = "1";
    }
  }

  function showChartPlaceholder() {
    if (els.skelChart) els.skelChart.classList.remove("is-hidden");
    if (els.canvas) els.canvas.style.opacity = "0";
    if (els.watermark) els.watermark.textContent = "";
  }

  function revealChart() {
    // First paint: metrics + chart + watermark together
    if (state.loading) {
      hideSkeleton();
    } else {
      if (els.skelChart) els.skelChart.classList.add("is-hidden");
      if (els.canvas) els.canvas.style.opacity = "1";
    }
    const coin = state.coins.find((c) => c.id === state.selectedId);
    if (els.watermark && coin) els.watermark.textContent = coin.symbol;
  }

  function fetchJson(url, ms = 9000) {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), ms);
    return fetch(url, { signal: ctrl.signal, cache: "no-store" })
      .then(async (res) => {
        if (!res.ok) throw new Error(`${res.status}`);
        return res.json();
      })
      .finally(() => clearTimeout(t));
  }

  function makeSpark(seed, len, base) {
    const out = [];
    let v = Number(base);
    if (!Number.isFinite(v) || v <= 0) v = 1;
    let s = Math.abs(Math.floor(Number(seed))) % 2147483646 || 1;
    for (let i = 0; i < len; i++) {
      s = (s * 16807) % 2147483647;
      const n = (s / 2147483647) * 2 - 1;
      v = Math.max(v * 0.97, Math.min(v * 1.03, v * (1 + n * 0.0035)));
      out.push(v);
    }
    return out;
  }

  function demoCoins() {
    return normalizeBoard(
      ASSETS.map((a) => ({
        id: a.id,
        name: a.name,
        symbol: a.symbol,
        pair: a.pair,
        image: a.image,
        usd: a.usd,
        rub: a.usd * state.usdRub,
        change: a.change,
        marketCap: a.usd * a.supply,
        volume: a.volume,
        supply: a.supply,
        tone: a.tone,
        sparkline: makeSpark(a.symbol.charCodeAt(0) * 97, 168, a.usd),
      }))
    );
  }

  async function loadUsdRub() {
    try {
      const data = await fetchJson(FX, 5000);
      if (data && data.rates && data.rates.RUB) state.usdRub = Number(data.rates.RUB);
    } catch {
      /* keep default */
    }
  }

  async function loadFromCoinGecko() {
    const ids = ASSETS.map((a) => a.id).join(",");
    const url =
      `${CG}/coins/markets?vs_currency=usd&ids=${ids}` +
      `&order=market_cap_desc&per_page=50&page=1&sparkline=true&price_change_percentage=24h`;
    const rows = await fetchJson(url);
    let prices = {};
    try {
      prices = await fetchJson(
        `${CG}/simple/price?ids=${ids}&vs_currencies=usd,rub&include_24hr_change=true`
      );
    } catch (err) {
      console.warn("CoinGecko simple/price failed", err);
    }

    return normalizeBoard(
      rows
        .map((row) => {
          const meta = ASSETS.find((a) => a.id === row.id);
          if (!meta) return null;
          const extra = prices[row.id] || {};
          const spark =
            (row.sparkline_in_7d && row.sparkline_in_7d.price) ||
            makeSpark(meta.symbol.charCodeAt(0), 168, row.current_price);
          return {
            id: row.id,
            name: row.name,
            symbol: String(row.symbol || meta.symbol).toUpperCase(),
            pair: meta.pair,
            image: meta.image,
            usd: extra.usd ?? row.current_price,
            rub: extra.rub ?? (extra.usd ?? row.current_price) * state.usdRub,
            change: extra.usd_24h_change ?? row.price_change_percentage_24h,
            marketCap: row.market_cap,
            volume: row.total_volume,
            supply: row.circulating_supply,
            tone: meta.tone,
            sparkline: spark,
          };
        })
        .filter(Boolean)
    );
  }

  async function loadFromBinance() {
    const tickers = await fetchJson(`${BN}/ticker/24hr`);
    const bySymbol = Object.fromEntries(tickers.map((t) => [t.symbol, t]));

    return normalizeBoard(
      ASSETS.map((a) => {
        const t = a.pair ? bySymbol[a.pair] : null;
        const usd = t ? Number(t.lastPrice) : a.usd;
        const change = t ? Number(t.priceChangePercent) : a.change;
        const volume = t ? Number(t.quoteVolume) : a.volume;
        return {
          id: a.id,
          name: a.name,
          symbol: a.symbol,
          pair: a.pair,
          image: a.image,
          usd,
          rub: usd * state.usdRub,
          change,
          marketCap: usd * a.supply,
          volume,
          supply: a.supply,
          tone: a.tone,
          sparkline: makeSpark(a.symbol.charCodeAt(0) * 13, 168, usd),
        };
      })
    );
  }

  async function loadMarkets() {
    await loadUsdRub();

    try {
      state.coins = await loadFromCoinGecko();
      state.source = "live";
      return;
    } catch (err) {
      console.warn("CoinGecko failed", err);
    }

    try {
      state.coins = await loadFromBinance();
      state.source = "exchange";
      return;
    } catch (err) {
      console.warn("Binance failed", err);
    }

    state.coins = demoCoins();
    state.source = "demo";
  }

  function coinImage(coin) {
    const meta = ASSETS.find((a) => a.id === coin.id);
    return meta?.image || coin.image;
  }

  function buildRail() {
    els.rail.innerHTML = "";
    state.coins.forEach((coin) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "coin" + (coin.id === state.selectedId ? " is-active" : "");
      btn.dataset.id = coin.id;
      btn.style.setProperty("--tone", coin.tone);
      const img = coinImage(coin);
      btn.innerHTML = `
        <span class="coin-rank">${coin.rank ?? "-"}</span>
        <img src="${img}" alt="" width="36" height="36" decoding="async">
        <span class="coin-copy">
          <strong>${coin.name}</strong>
          <small>${money(coin.usd, "USD")} · ${money(coin.rub, "RUB")}</small>
        </span>
        <span class="coin-ghost">${coin.symbol}</span>
      `;
      btn.addEventListener("click", () => selectCoin(coin.id));
      els.rail.appendChild(btn);
    });
  }

  function updateRail() {
    if (!els.rail.children.length) {
      buildRail();
      return;
    }
    state.coins.forEach((coin) => {
      const btn = els.rail.querySelector(`[data-id="${coin.id}"]`);
      if (!btn) return;
      btn.classList.toggle("is-active", coin.id === state.selectedId);
      btn.style.setProperty("--tone", coin.tone);
      const rank = btn.querySelector(".coin-rank");
      const small = btn.querySelector("small");
      if (rank) rank.textContent = coin.rank ?? "-";
      if (small) small.textContent = `${money(coin.usd, "USD")} · ${money(coin.rub, "RUB")}`;
      // never rewrite img src - avoids icon flicker
    });
  }

  function preloadIcons() {
    ASSETS.forEach((a) => {
      const img = new Image();
      img.decoding = "async";
      img.src = a.image;
    });
  }

  function setMetric(key, value, toneClass) {
    const node = metricNodes[key];
    if (!node) return;
    node.querySelector("b").textContent = value;
    node.classList.remove("is-up", "is-down");
    if (toneClass) node.classList.add(toneClass);
  }

  function showStage(coin) {
    els.stageEmpty.classList.add("is-hidden");
    els.stageBody.classList.remove("is-hidden");
    // Watermark only with chart in revealChart - no early flash

    const chgClass = coin.change == null ? "" : coin.change >= 0 ? "is-up" : "is-down";
    setMetric("rank", coin.rank ?? "-");
    setMetric("name", coin.name);
    setMetric("usd", money(coin.usd, "USD"));
    setMetric("rub", money(coin.rub, "RUB"));
    setMetric("mcap", compactMoney(coin.marketCap, "USD"));
    setMetric("vol", compactMoney(coin.volume, "USD"));
    setMetric(
      "supply",
      coin.supply == null ? "-" : Math.round(coin.supply).toLocaleString("ru-RU")
    );
    setMetric("chg", pct(coin.change), chgClass);
    tickClock();
  }

  function sparkPoints(coin, days) {
    const spark = coin.sparkline || [];
    if (!spark.length) return [];
    let slice = spark;
    if (days === "1" && spark.length > 24) slice = spark.slice(-24);
    const now = Date.now();
    const step = days === "1" ? 3600e3 : days === "7" ? 3600e3 : 3 * 3600e3;
    return slice.map((v, i) => ({
      t: now - (slice.length - 1 - i) * step,
      v,
    }));
  }

  async function fetchChartPoints(coin, days) {
    const interval = days === "1" ? "15m" : days === "7" ? "1h" : "4h";
    const limit = days === "1" ? 96 : days === "7" ? 168 : 180;

    // Binance klines - works from browsers (USDCUSDT etc.)
    if (coin.pair) {
      try {
        const rows = await fetchJson(
          `${BN}/klines?symbol=${coin.pair}&interval=${interval}&limit=${limit}`
        );
        if (Array.isArray(rows) && rows.length) {
          return rows.map((k) => ({ t: k[0], v: Number(k[4]) }));
        }
      } catch (err) {
        console.warn("Binance klines failed", err);
      }
    }

    // CoinGecko - needed for USDT (no USDT/USDT pair)
    try {
      const res = await fetchJson(
        `${CG}/coins/${coin.id}/market_chart?vs_currency=usd&days=${days}`
      );
      const points = (res.prices || []).map((p) => ({ t: p[0], v: p[1] }));
      if (points.length) return points;
    } catch (err) {
      console.warn("CoinGecko chart failed", err);
    }

    return sparkPoints(coin, days);
  }

  async function loadChart(coinId, days) {
    const req = ++state.chartReq;
    const coin = state.coins.find((c) => c.id === coinId);
    if (!coin) {
      if (state.loading) {
        if (els.chartError) {
          els.chartError.textContent = "График временно недоступен";
          els.chartError.classList.remove("is-hidden");
        }
        revealChart();
      }
      return;
    }

    els.chartLabel.textContent =
      days === "1" ? "График 24ч" : days === "7" ? "График 7д" : "График 30д";

    if (els.chartError) {
      els.chartError.classList.add("is-hidden");
      els.chartError.textContent = "";
    }

    showChartPlaceholder();
    if (state.chart) {
      state.chart.destroy();
      state.chart = null;
    }

    try {
      let points = await fetchChartPoints(coin, days);
      if (req !== state.chartReq) return;
      if (!points.length) points = sparkPoints(coin, days);
      if (!points.length) throw new Error("empty");

      const painted = await drawChart(points, coin.change ?? 0, { days, req });
      if (req !== state.chartReq || !painted) return;
      revealChart();
      if (state.chart) state.chart.resize();
    } catch (err) {
      console.warn(err);
      if (req !== state.chartReq) return;
      const fallback = sparkPoints(coin, days);
      if (fallback.length) {
        try {
          const painted = await drawChart(fallback, coin.change ?? 0, { days, req });
          if (req !== state.chartReq || !painted) return;
          revealChart();
          if (state.chart) state.chart.resize();
          return;
        } catch (drawErr) {
          console.warn(drawErr);
        }
      }
      if (els.chartError) {
        els.chartError.textContent = "График временно недоступен";
        els.chartError.classList.remove("is-hidden");
      }
      revealChart();
    }
  }

  function nextFrame() {
    return new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  }

  async function drawChart(points, change, opts = {}) {
    if (!els.canvas || !points.length) return false;
    const req = opts.req;
    await nextFrame();
    if (req != null && req !== state.chartReq) return false;

    const days = opts.days || state.days;
    const up = change >= 0;
    const stroke = up ? "rgba(62, 207, 142, 0.95)" : "rgba(224, 106, 92, 0.95)";
    const fill = up ? "rgba(62, 207, 142, 0.22)" : "rgba(224, 106, 92, 0.18)";
    const showTime = days === "1" && points.length < 80;
    const clean = points.filter((p) => Number.isFinite(p.v));
    if (!clean.length) return false;
    const labels = clean.map((p) =>
      new Date(p.t).toLocaleString("ru-RU", {
        month: "short",
        day: "numeric",
        hour: showTime ? "2-digit" : undefined,
        minute: showTime ? "2-digit" : undefined,
      })
    );
    const values = clean.map((p) => p.v);
    const min = Math.min(...values);
    const max = Math.max(...values);

    if (typeof Chart === "undefined") {
      drawFallbackCanvas(values, stroke, fill);
      return true;
    }

    // Always recreate once with final data - never morph spark to live
    if (state.chart) {
      state.chart.destroy();
      state.chart = null;
    }
    if (req != null && req !== state.chartReq) return false;

    state.chart = new Chart(els.canvas, {
      type: "line",
      data: {
        labels,
        datasets: [
          {
            data: values,
            borderColor: stroke,
            backgroundColor: fill,
            borderWidth: 2.5,
            fill: true,
            tension: 0.3,
            pointRadius: 0,
            pointHoverRadius: 4,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        interaction: { mode: "index", intersect: false },
        plugins: {
          legend: { display: false },
          tooltip: {
            callbacks: {
              label(ctx) {
                return ` $${Number(ctx.parsed.y).toLocaleString("ru-RU", {
                  maximumFractionDigits: 6,
                })}`;
              },
            },
          },
        },
        scales: {
          x: {
            ticks: {
              maxTicksLimit: 6,
              padding: 6,
              color: "rgba(138, 160, 176, 0.8)",
              font: { size: 10, family: "IBM Plex Mono" },
            },
            grid: { color: "rgba(168, 198, 214, 0.08)" },
            border: { display: false },
            afterFit(scale) {
              scale.height = Math.max(scale.height, 28);
            },
          },
          y: {
            position: "right",
            suggestedMin: min * 0.995,
            suggestedMax: max * 1.005,
            ticks: {
              maxTicksLimit: 4,
              padding: 8,
              color: "rgba(138, 160, 176, 0.8)",
              font: { size: 10, family: "IBM Plex Mono" },
              callback: (v) =>
                Number(v).toLocaleString("ru-RU", {
                  maximumFractionDigits: v < 2 ? 4 : 2,
                }),
            },
            grid: { color: "rgba(168, 198, 214, 0.08)" },
            border: { display: false },
            afterFit(scale) {
              scale.width = 52;
            },
          },
        },
      },
    });
    return true;
  }

  function drawFallbackCanvas(values, stroke, fill) {
    const canvas = els.canvas;
    const parent = canvas.parentElement;
    const w = parent.clientWidth || 640;
    const h = parent.clientHeight || 280;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.floor(w * dpr);
    canvas.height = Math.floor(h * dpr);
    canvas.style.width = `${w}px`;
    canvas.style.height = `${h}px`;
    const ctx = canvas.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    const min = Math.min(...values);
    const max = Math.max(...values);
    const pad = 16;
    const span = max - min || 1;
    const last = values.length - 1 || 1;

    const pts = values.map((v, i) => ({
      x: pad + (i / last) * (w - pad * 2),
      y: h - pad - ((v - min) / span) * (h - pad * 2),
    }));

    ctx.beginPath();
    pts.forEach((p, i) => (i === 0 ? ctx.moveTo(p.x, p.y) : ctx.lineTo(p.x, p.y)));
    ctx.lineTo(pts[pts.length - 1].x, h - pad);
    ctx.lineTo(pts[0].x, h - pad);
    ctx.closePath();
    ctx.fillStyle = fill;
    ctx.fill();

    ctx.beginPath();
    pts.forEach((p, i) => (i === 0 ? ctx.moveTo(p.x, p.y) : ctx.lineTo(p.x, p.y)));
    ctx.strokeStyle = stroke;
    ctx.lineWidth = 2;
    ctx.stroke();
  }

  async function selectCoin(id) {
    const prev = state.selectedId;
    state.selectedId = id;
    const coin = state.coins.find((c) => c.id === id);
    if (!coin) return;
    updateRail();
    showStage(coin);
    els.app.classList.remove("rail-open");

    if (prev !== id) {
      if (state.chart) {
        state.chart.destroy();
        state.chart = null;
      }
    }
    await loadChart(id, state.days);
  }

  document.querySelectorAll(".range").forEach((btn) => {
    btn.addEventListener("click", async () => {
      document.querySelectorAll(".range").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      state.days = btn.dataset.days;
      if (state.selectedId) {
        if (state.chart) {
          state.chart.destroy();
          state.chart = null;
        }
        await loadChart(state.selectedId, state.days);
      }
    });
  });

  els.railToggle.addEventListener("click", () => {
    els.app.classList.toggle("rail-open");
  });

  window.addEventListener("resize", () => {
    if (state.chart) state.chart.resize();
  });

  function lockAssetImages(coins) {
    return coins.map((c) => {
      const meta = ASSETS.find((a) => a.id === c.id);
      return meta ? { ...c, image: meta.image, tone: meta.tone } : c;
    });
  }

  async function boot() {
    preloadIcons();
    els.railToggle.hidden = false;
    showSkeleton();
    setInterval(tickClock, 1000);

    try {
      await loadMarkets();
      state.coins = lockAssetImages(state.coins);
      if (!state.coins.length) throw new Error("empty board");
      // Keep stage skeleton until first chart ready (revealChart → hideSkeleton)
      buildRail();
      await selectCoin(state.coins[0].id);
    } catch (err) {
      console.warn(err);
      state.coins = demoCoins();
      state.source = "demo";
      buildRail();
      if (state.coins[0]) await selectCoin(state.coins[0].id);
    }
  }

  boot();
})();
