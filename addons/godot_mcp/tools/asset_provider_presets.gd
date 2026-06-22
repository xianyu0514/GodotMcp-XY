class_name AssetProviderPresets
extends RefCounted

# Ready-made request templates for external image/audio/TTS providers so users
# only have to pick a provider and supply their own API key (via an OS env var)
# instead of hand-crafting endpoint / headers / response_field. The plugin never
# ships or stores an API key: the key is read from the named environment variable
# at request time and injected into the auth header, never logged or persisted.
#
# Template placeholders substituted at request time by generate_asset:
#   {prompt}  {width}  {height}
# The api key is injected into `auth_header` as `auth_prefix` + key.

const PRESETS: Dictionary = {
	"openai_image": {
		"label": "OpenAI Images (gpt-image-1)",
		"category": "image",
		"endpoint": "https://api.openai.com/v1/images/generations",
		"http_method": "POST",
		"api_key_env": "OPENAI_API_KEY",
		"auth_header": "Authorization",
		"auth_prefix": "Bearer ",
		"headers": {"Content-Type": "application/json"},
		"request_body": {
			"model": "gpt-image-1",
			"prompt": "{prompt}",
			"size": "{width}x{height}",
			"n": 1,
			"response_format": "b64_json"
		},
		"response_field": "data.0.b64_json"
	},
	"stability_image": {
		"label": "Stability AI (SD3 core)",
		"category": "image",
		"endpoint": "https://api.stability.ai/v2beta/stable-image/generate/core",
		"http_method": "POST",
		"api_key_env": "STABILITY_API_KEY",
		"auth_header": "Authorization",
		"auth_prefix": "Bearer ",
		"headers": {"Content-Type": "application/json", "Accept": "application/json"},
		"request_body": {"prompt": "{prompt}", "output_format": "png"},
		"response_field": "image"
	},
	"elevenlabs_tts": {
		"label": "ElevenLabs TTS",
		"category": "audio",
		"endpoint": "https://api.elevenlabs.io/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM",
		"http_method": "POST",
		"api_key_env": "ELEVENLABS_API_KEY",
		"auth_header": "xi-api-key",
		"auth_prefix": "",
		"headers": {"Content-Type": "application/json", "Accept": "audio/mpeg"},
		"request_body": {"text": "{prompt}", "model_id": "eleven_multilingual_v2"},
		"response_field": ""
	},
	"local_sd_webui": {
		"label": "Local Stable Diffusion (AUTOMATIC1111 WebUI)",
		"category": "image",
		"endpoint": "http://127.0.0.1:7860/sdapi/v1/txt2img",
		"http_method": "POST",
		"api_key_env": "",
		"auth_header": "",
		"auth_prefix": "",
		"headers": {"Content-Type": "application/json"},
		"request_body": {"prompt": "{prompt}", "width": "{width}", "height": "{height}", "steps": 20},
		"response_field": "images.0"
	}
}

# Stable, display-ordered list of preset ids for UI dropdowns.
static func preset_ids() -> Array:
	return ["openai_image", "stability_image", "elevenlabs_tts", "local_sd_webui"]

static func has_preset(preset_id: String) -> bool:
	return PRESETS.has(preset_id)

static func get_preset(preset_id: String) -> Dictionary:
	if not PRESETS.has(preset_id):
		return {}
	return (PRESETS[preset_id] as Dictionary).duplicate(true)

static func label_for(preset_id: String) -> String:
	if not PRESETS.has(preset_id):
		return preset_id
	return str((PRESETS[preset_id] as Dictionary).get("label", preset_id))
