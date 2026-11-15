# Howdy rubberstamp: tells the Face ID-style popup that the face was recognised, so it
# can draw its tick before compare.py closes it. Never blocks a sign-in: it always
# returns True, and any error here is ignored by Howdy because the rule is "failsafe".
# Installed by the Yoga Slim 7 kit (install.sh); enabled in /etc/howdy/config.ini with
#   [rubberstamps] enabled = true, stamp_rules = faceid 1s failsafe
import time

from rubberstamps import RubberStamp


class faceid(RubberStamp):
	def declare_config(self):
		"""How long the tick stays on screen, in seconds"""
		self.options["hold"] = 0.35

	def run(self):
		try:
			self.set_ui_text("_SUCCESS", self.UI_TEXT)
			time.sleep(min(float(self.options["hold"]), 0.8))
		except Exception:
			pass
		return True
