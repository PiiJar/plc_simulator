import React, { useRef, useState, useEffect } from 'react';

/**
 * Draggable panel component for floating UI elements
 * 
 * @param {Object} props
 * @param {string} props.title - Panel title
 * @param {Function} props.onClose - Close handler
 * @param {React.ReactNode} props.children - Panel content
 * @param {number} [props.width=520] - Panel width
 */
function DraggablePanel({ title, onClose, children, width = 520 }) {
  const panelRef = useRef(null);
  const [pos, setPos] = useState({ x: 24, y: 24 });
  const [dragging, setDragging] = useState(false);
  const offsetRef = useRef({ x: 0, y: 0 });

  useEffect(() => {
    const handleMouseMove = (e) => {
      if (!dragging) return;
      setPos({ x: e.clientX - offsetRef.current.x, y: e.clientY - offsetRef.current.y });
    };
    const handleMouseUp = () => setDragging(false);
    window.addEventListener('mousemove', handleMouseMove);
    window.addEventListener('mouseup', handleMouseUp);
    return () => {
      window.removeEventListener('mousemove', handleMouseMove);
      window.removeEventListener('mouseup', handleMouseUp);
    };
  }, [dragging]);

  const onMouseDown = (e) => {
    const rect = panelRef.current?.getBoundingClientRect();
    if (!rect) return;
    offsetRef.current = { x: e.clientX - rect.left, y: e.clientY - rect.top };
    setDragging(true);
    e.preventDefault();
  };

  return (
    <div
      ref={panelRef}
      style={{
        position: 'fixed',
        top: pos.y,
        left: pos.x,
        width: 'fit-content',
        minWidth: width,
        maxWidth: '90vw',
        maxHeight: '85vh',
        overflow: 'auto',
        background: '#ffffff',
        border: '1px solid #d0d0d0',
        boxShadow: '0 6px 18px rgba(0,0,0,0.15)',
        borderRadius: 8,
        padding: 12,
        zIndex: 2000,
        cursor: dragging ? 'grabbing' : 'default'
      }}
    >
      <div
        style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8, cursor: 'grab', userSelect: 'none' }}
        onMouseDown={onMouseDown}
      >
        <div style={{ fontWeight: 700, fontSize: 15 }}>{title}</div>
        <button
          onClick={onClose}
          style={{
            border: 'none',
            background: 'transparent',
            cursor: 'pointer',
            fontSize: 16,
            fontWeight: 700,
            lineHeight: 1
          }}
          aria-label="Sulje"
        >
          ×
        </button>
      </div>
      {children}
    </div>
  );
}

export default DraggablePanel;
