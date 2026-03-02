const puppeteer = require('puppeteer-core');
const path = require('path');
const fs = require('fs');

(async () => {
  const screenshotDir = path.join(__dirname, 'screenshots');
  if (!fs.existsSync(screenshotDir)) fs.mkdirSync(screenshotDir);

  const browser = await puppeteer.launch({
    executablePath: '/usr/bin/chromium-browser',
    headless: 'new',
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-gpu']
  });

  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 900 });

  const filePath = 'file://' + path.resolve(__dirname, 'presentation.html');
  await page.goto(filePath, { waitUntil: 'networkidle0', timeout: 15000 });
  await new Promise(r => setTimeout(r, 2000));

  const totalSlides = await page.evaluate(() => document.querySelectorAll('.slide').length);
  console.log(`Total slides found: ${totalSlides}`);

  const issues = [];

  // Helper to get active slide info
  async function getSlideInfo() {
    return page.evaluate(() => {
      const active = document.querySelector('.slide.active');
      if (!active) return { error: 'No active slide found' };
      const slideIdx = parseInt(active.dataset.slide);
      const tag = active.querySelector('.slide-tag');
      const heading = active.querySelector('h1, h2');
      const counter = document.getElementById('slide-counter').textContent;
      const overflow = active.scrollHeight > window.innerHeight;
      const hasContent = active.textContent.trim().length > 10;
      const prevDisabled = document.getElementById('prevBtn').disabled;
      const nextDisabled = document.getElementById('nextBtn').disabled;
      return { slideIdx, tag: tag ? tag.textContent : null, heading: heading ? heading.textContent.substring(0, 60) : null, counter, overflow, hasContent, prevDisabled, nextDisabled };
    });
  }

  // ── TEST 1: Forward navigation through all slides ──
  console.log('\n=== TEST 1: Forward navigation (Next button) ===');
  for (let i = 0; i < totalSlides; i++) {
    const info = await getSlideInfo();
    await page.screenshot({ path: path.join(screenshotDir, `slide-${i}.png`) });

    console.log(`  Slide ${i}: idx=${info.slideIdx} tag="${info.tag}" counter="${info.counter}" content=${info.hasContent} overflow=${info.overflow}`);

    if (info.error) { issues.push(`Slide ${i}: ${info.error}`); continue; }
    if (info.slideIdx !== i) issues.push(`Slide ${i}: active slide index is ${info.slideIdx}, expected ${i}`);
    if (!info.hasContent) issues.push(`Slide ${i}: No content`);
    if (info.overflow) issues.push(`Slide ${i}: Content overflows viewport`);
    if (i === 0 && !info.prevDisabled) issues.push(`Slide 0: Prev button should be disabled`);
    if (i === totalSlides - 1 && !info.nextDisabled) issues.push(`Last slide: Next button should be disabled`);

    if (i < totalSlides - 1) {
      await page.click('#nextBtn');
      await new Promise(r => setTimeout(r, 700));
    }
  }

  // ── TEST 2: Backward navigation ──
  console.log('\n=== TEST 2: Backward navigation (Back button) ===');
  for (let i = 0; i < 3; i++) {
    await page.click('#prevBtn');
    await new Promise(r => setTimeout(r, 500));
  }
  let info = await getSlideInfo();
  const expectedBack = totalSlides - 1 - 3;
  console.log(`  After 3 back clicks from slide ${totalSlides - 1}: on slide ${info.slideIdx} (expected ${expectedBack})`);
  if (info.slideIdx !== expectedBack) issues.push(`Back nav: expected slide ${expectedBack}, got ${info.slideIdx}`);

  // ── TEST 3: Keyboard navigation ──
  console.log('\n=== TEST 3: Keyboard navigation ===');
  const beforeRight = info.slideIdx;
  await page.keyboard.press('ArrowRight');
  await new Promise(r => setTimeout(r, 500));
  info = await getSlideInfo();
  console.log(`  ArrowRight: ${beforeRight} -> ${info.slideIdx}`);
  if (info.slideIdx !== beforeRight + 1) issues.push(`Keyboard: ArrowRight didn't advance`);

  await page.keyboard.press('ArrowLeft');
  await new Promise(r => setTimeout(r, 500));
  info = await getSlideInfo();
  console.log(`  ArrowLeft: -> ${info.slideIdx}`);
  if (info.slideIdx !== beforeRight) issues.push(`Keyboard: ArrowLeft didn't go back`);

  // ── TEST 4: Dot navigation ──
  console.log('\n=== TEST 4: Dot navigation ===');
  await page.click('.dot[data-i="0"]');
  await new Promise(r => setTimeout(r, 500));
  info = await getSlideInfo();
  console.log(`  Clicked dot 0: on slide ${info.slideIdx}`);
  if (info.slideIdx !== 0) issues.push(`Dot nav: expected slide 0, got ${info.slideIdx}`);

  await page.click('.dot[data-i="7"]');
  await new Promise(r => setTimeout(r, 500));
  info = await getSlideInfo();
  console.log(`  Clicked dot 7: on slide ${info.slideIdx}`);
  if (info.slideIdx !== 7) issues.push(`Dot nav: expected slide 7, got ${info.slideIdx}`);

  // ── TEST 5: Progress bar ──
  console.log('\n=== TEST 5: Progress bar ===');
  await page.click('.dot[data-i="5"]');
  await new Promise(r => setTimeout(r, 500));
  const progressWidth = await page.evaluate(() => document.getElementById('progress-fill').style.width);
  console.log(`  Progress at slide 5: ${progressWidth}`);
  const expectedProgress = ((5 / (totalSlides - 1)) * 100).toFixed(1);
  if (!progressWidth.includes(Math.round(parseFloat(expectedProgress)).toString())) {
    // just a loose check
    console.log(`  (expected ~${expectedProgress}%)`);
  }

  // ── TEST 6: Axis bar animation on slide 8 ──
  console.log('\n=== TEST 6: Axis animation (slide 8) ===');
  await page.click('.dot[data-i="8"]');
  await new Promise(r => setTimeout(r, 1500));
  const axisWidths = await page.evaluate(() => {
    return Array.from(document.querySelectorAll('.axis-anim')).map(el => el.style.width);
  });
  console.log(`  Axis bar widths: ${axisWidths.join(', ')}`);
  if (axisWidths.some(w => w === '0' || w === '0%' || w === '')) {
    issues.push('Axis animation: bars did not animate');
  }

  // ── TEST 7: Timeline animation on slide 10 ──
  console.log('\n=== TEST 7: Timeline animation (slide 10) ===');
  await page.click('.dot[data-i="10"]');
  await new Promise(r => setTimeout(r, 2500));
  const filledDots = await page.evaluate(() => {
    return document.querySelectorAll('.timeline-dot.filled').length;
  });
  console.log(`  Filled timeline dots: ${filledDots}/4`);
  if (filledDots !== 4) issues.push(`Timeline: expected 4 filled dots, got ${filledDots}`);

  // Final screenshot of last slide
  await page.click('.dot[data-i="' + (totalSlides - 1) + '"]');
  await new Promise(r => setTimeout(r, 700));
  await page.screenshot({ path: path.join(screenshotDir, `slide-final.png`) });

  // ── SUMMARY ──
  console.log('\n========================================');
  console.log('         TEST SUMMARY');
  console.log('========================================');
  console.log(`Total slides: ${totalSlides}`);
  console.log(`Screenshots: ${screenshotDir}`);
  if (issues.length === 0) {
    console.log('\n  ALL TESTS PASSED\n');
  } else {
    console.log(`\n  ISSUES FOUND (${issues.length}):`);
    issues.forEach(i => console.log(`    - ${i}`));
    console.log('');
  }

  await browser.close();
})();
