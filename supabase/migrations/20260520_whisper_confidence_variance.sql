-- Randomize whisper confidence on insert so messages don't all hit the same
-- hedging tier. Adds category-specific variance around the base value.
-- combat_nearby: ±15  (witnessed event, tighter spread)
-- general_briefing: ±25 (broad scan, noisier)
-- everything else: ±20

CREATE OR REPLACE FUNCTION randomize_whisper_confidence()
RETURNS TRIGGER AS $$
DECLARE
  v_variance INT;
BEGIN
  v_variance := CASE NEW.category
    WHEN 'combat_nearby'    THEN 15
    WHEN 'general_briefing' THEN 25
    ELSE 20
  END;
  NEW.confidence := LEAST(95, GREATEST(10,
    NEW.confidence + FLOOR(RANDOM() * (v_variance * 2 + 1) - v_variance)::INT
  ));
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS whispers_randomize_confidence ON whispers;
CREATE TRIGGER whispers_randomize_confidence
  BEFORE INSERT ON whispers
  FOR EACH ROW EXECUTE FUNCTION randomize_whisper_confidence();
