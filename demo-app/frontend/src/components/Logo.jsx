// Kestrel Market wordmark: a small falcon glyph + name.
export default function Logo({ dark = false }) {
  const ink = dark ? "#fff" : "#064e3b";
  const accent = dark ? "#34d399" : "#059669";
  return (
    <div className="flex items-center gap-2.5 select-none">
      <svg width="30" height="30" viewBox="0 0 32 32" fill="none" aria-hidden="true">
        <rect width="32" height="32" rx="9" fill={accent} />
        <path
          d="M9 20.5c3.2-0.3 5.2-1.9 6.4-4.1-2 0.6-3.6 0.4-4.8-0.5 2.6 0.1 4.5-0.8 5.9-2.7-1.4 0.3-2.6 0.2-3.6-0.4 3.1-0.2 5.4-1.8 7.1-4.8 0.5 3.1-0.1 5.7-1.6 7.9 1.1-0.2 2-0.7 2.8-1.6-0.4 2.2-1.6 3.8-3.4 4.9 1 0.1 1.9-0.1 2.8-0.6-1.6 2.3-4.2 3.6-7.9 3.9-0.6 0-1.2 0-1.8-0.1l-0.5-0.3z"
          fill="#fff"
        />
      </svg>
      <div className="leading-none">
        <div className="text-[15px] font-extrabold tracking-tight" style={{ color: ink }}>
          Kestrel<span style={{ color: accent }}>Market</span>
        </div>
      </div>
    </div>
  );
}
