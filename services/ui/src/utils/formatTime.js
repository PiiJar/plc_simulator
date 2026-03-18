export const formatTime = (ms) => {
  const totalMs = Math.max(0, Math.floor(ms));
  const hours = Math.floor(totalMs / 3600000).toString().padStart(2, '0');
  const minutes = Math.floor((totalMs % 3600000) / 60000).toString().padStart(2, '0');
  const seconds = Math.floor((totalMs % 60000) / 1000).toString().padStart(2, '0');
  const millis = (totalMs % 1000).toString().padStart(3, '0');
  return `${hours}:${minutes}:${seconds}.${millis}`;
};
