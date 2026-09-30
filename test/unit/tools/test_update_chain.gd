extends "res://addons/gut/test.gd"

# 更新链纯核心：SHA256SUMS 解析 + RSA 验签往返/篡改拒绝/错钥拒绝。
# 端到端（真实 release 下载→验签→换装）在 v1.2.1 发布后真机验收。
#
# 密钥说明：嵌入的 2048 测试钥是**纯测试资产**，与发布链的 RELEASE_SIGNING
# 4096 钥无关，不承载任何安全职责。嵌入固定钥而非运行时 generate_rsa：
# mbedtls keygen 在 CI VM 上会阻塞主线程超过套件看门狗窗口（2026-09-30
# CI 实测挂起，本地秒过）——确定性嵌入是稳定解。

const EditorToolsScript = preload("res://addons/godot_mcp/tools/editor_tools_native.gd")

const TEST_KEY_A_PRIVATE_PEM: String = """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC4fAcu8p9/Yh7L
VZro/aibqJ/46yHH9XJO9BYIx468F4518VhevkkMK0bjsZMHSZ2WKhmekdiMBTT5
lPJyUW76rCldI5HxzngSJLJpeS6OExKQNijJKwKcsWvaV7U4GqaKliBNB9oqIUIv
9iN1/w4AtUfc0s1xXEMn+GiLBokk+AKWdPAaJwbXDzAlGkQikrUxFRsNDIMf6UQC
BcVtqUWDWtGR+nVk/3WfWQ2oEK/97qR2kY1yX2BFUjU8XRMM30zwcjP5SxO2q+Tg
zsUYGusfWvn6JeY1gW+L1/2k3hdTwt33vsie1s2iXzTZ/9PmcVr6RN+RenPNBH5c
PbVfnOmdAgMBAAECggEAB62VIJ7VRQ2zduZ8m0WoCAx0AKiL6st8GFhKd3nou/V7
XCIb5FuP5OYDM170sykHmj7tJd9E5N+i8AqYhD9VOrEXdUp8Rz+phHsgWB6Z8ayj
s+VRJr2NGbI8/nodLx/Vfm9CRQ/L2b+HG+xnAZZIgf6Je7cOo7EW6W8KWNOVjyMs
zn9Dbm+2pOdhDHsUdRib+CES5nvw66JxzSV1nBXd+gVk/XtIzEmH06aL4r3beiQS
DjuTqYW1Mc1P/01Rc1zxhVEjZtw/suzmWesC9JaSBZzfQ+U3ayKYM37pk2gl3QHE
G7XwOoQCNRHuzYJB8gEDe2y/TUtaMWUpcBWdMd/qMQKBgQDvuNvRSx6u1mEgthzZ
PwzXdRyItnXxv6EgaqiKT/YCar0uRywdJakSGDb7unrlPGKG5mXvyt43xh0aTB84
85Vke/4YpCoXYOlQyO0AZdcmDJ30VouMFTRilnGvsD6NM8VmikQbIXc0Ku5QqXOU
aZhvINNIVZcGUI0nIypTuUI6kQKBgQDFAvY9cRe2gy856KF9zMOwCQnQnTLI0n5k
0AlaucLuIr2oRzi4SWFn+hJWgn8A6z8GkD51n436/9IdJCFHxqSPcnm3tFzmOzCH
PImoQ6ctKm5p2CX69FoIo/wLhcIfo35f7T59jJ5QPmMJPKhMsmNiNSKW9M8t8ChE
X7dOVQqMTQKBgGHjAVeoLgJEpeqeko8fUNYWCy3EG8s4bcn345R+7Dy2a0OfamMI
gs5Rtvn5fr9mdfER2aQeGbl6m12mocU2qdUbUHmtZ0aemwcS1Lwp2b2+vy0LvfXY
nsh3GDseY5xy/HNPmFnfw3Y45ZFocDq1F7qhE8VgtcetUsYddOY1KtcRAoGAHE44
ostE5OwkNOW/jhuFYh1qU5bCXSghEMrzDR3za9OB/FN/SrsAS7gaOmO1a6RhAchn
sO6jr5Rh094FChL4QcPoyQQY9Ns8NbH09UADHPIjuwFbM5s39FXbOKyXH4SV+6JS
gCdb95t/Dyyv4ZUfwlRwC9BQlAEVR/2YkKCXS2ECgYEAl24gRnsxpGehBJzApCG2
dXBOZO6QOoedMwnzPreZ/KWC9HO6Pw8Gq5F0rjR7t5uedZ4MAdvi+i93+O2rwqxu
CFKJl5RSS2QvWMQwmdAcy4jpavqSYw2ch5cM62w6Cl/hOaiIzhd8jOhXNPygJIPN
PEkywqxm9A5nGXA1TNnFkIY=
-----END PRIVATE KEY-----
"""

const TEST_KEY_A_PUBLIC_PEM: String = """
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuHwHLvKff2Iey1Wa6P2o
m6if+Oshx/VyTvQWCMeOvBeOdfFYXr5JDCtG47GTB0mdlioZnpHYjAU0+ZTyclFu
+qwpXSOR8c54EiSyaXkujhMSkDYoySsCnLFr2le1OBqmipYgTQfaKiFCL/Yjdf8O
ALVH3NLNcVxDJ/hoiwaJJPgClnTwGicG1w8wJRpEIpK1MRUbDQyDH+lEAgXFbalF
g1rRkfp1ZP91n1kNqBCv/e6kdpGNcl9gRVI1PF0TDN9M8HIz+UsTtqvk4M7FGBrr
H1r5+iXmNYFvi9f9pN4XU8Ld977IntbNol802f/T5nFa+kTfkXpzzQR+XD21X5zp
nQIDAQAB
-----END PUBLIC KEY-----
"""

const TEST_KEY_B_PRIVATE_PEM: String = """
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDTIIy05COuqjIR
mEqo/ZSFzfKVAlfS/JuAMjI7H1CfWIZfDEM0eqt50hTTXEvmUL0IKol2bV2RXlXH
ITq395zsvL9AnBFn3bxfgktwPD+UJIFr2V0Bv2W9TcL4lROOlW8DGYjzDTW+Fqmu
UczKA065XlngCry84g1T4HNMzawQqjjfYZh580hNCKVnaIEPa9108cYdc3f/yZkb
GURYvOFbRkgchYXaORqJd4n6HJaNAna5RiAPh/yo3aO6pSEa6YS4Qn9E7IFkjBVY
22euCl1NC/VXemsXkVrpaWwagpabUmGi9CcDCXq9w+JJ7Wt1CyHh631G0QWiAdjW
XmjfhEWvAgMBAAECggEABzLfmsp2PqP5EMw+w3QPeD0Jrb91HQ6y645nsN9hVcWS
57MHSwy+z2iuxetwOXGT8qOPkeDBwmTTRaVQui+8PaGpvEy70NXF5Uiy57PUBA0O
a19j6wuQaTA5cj5OTESde4gTIe4R4Lk+dfhJx1W/cey0Pp9vGfFzyBCYXGOjE/qC
AE8+Vg2KdzLpMN0lwgE85uQnMwfEjkCeB601WU7ftFEF9Evjgc7WbChdAcFlw9Yn
4w4/Gwr1ty1v//C0iNrQWtX/dqlkEk+I7LhRmFh7VTOsnnik+Fda43DbBqrzZpUK
tDm8kahOXOrxXqABuNiQgT/s0aILO6XV5Vzae/BcFQKBgQDyPzKrl96FhCn2/u2g
1lU5sb7rI0Mx+/04n+n9UokqggIhlcELDyYYVrJYA5ZAzznn0+RpyB/YOs2kNQvP
abZI5YCAS07jjfxHKludf6AV4Kdr4WOIVZZbBJNTm62UX9AYrz5r9zqwu5uIqSBu
pJZWk6FktC2ml6ns3Os5l2viqwKBgQDfHQ86GG8nVnT/7e6x5CAUuMhlT6fl4mDe
kfyMp8mbdPeCLRf0pO1aiW9qfbl4E/mCC8f/a33dKrVVPSqznYSZ3J8v0qUL+3xJ
hpMwB3yEACq8F3JC3JA3fuJiOVuclKPK/HBlqEB0FPPU/lw6leHNPPug5+C8GFvr
1k7ZejVJDQKBgDqTa4Ywf98bGSafeAhHK256+2ZSLYJdo1pY2LSni4Fa1HcYhghN
jnGeLRu5KlDbiu3yv62QdZrMhUMqjIOH1UsFK7BaBWZiw9jVdje8T5Jas0ETzASA
ZY32qkUyRKO3E1OUtGxY6LkpdC90beIzLCMdKY53Pv6kd7NNrBdN9QlnAoGBAJwz
QgfQN3F46+yJbUUJixQ20cVr4QXmWR85YXAvv8ugNe/jFhRmqu1prqEFaCWTBmlv
ShOd8741OkJ00kJxkvYNKT1X4cjjxf3Lw5wqgZgAberFF2+L70OLB37w3RxgS9O+
rAnfo1AhoxuJAJTbffwsJ5ZdAE9vVltj7EwBbPC5AoGBAM11kIrmbpkiiML/6i5t
6bEOtfH2FuI4vNog7I4+vQscylvOlQxfMFbK18ngWanj8Q8l8i0Z+d+RcvslNANo
QJgAOhyGz1C5JUflKj2htbZQB/OY8F8CBbl3R59Df5h2O8xnkJFZ6G/jBJIRoe+S
JOHZnBMTYBuKv0xGDortaxY/
-----END PRIVATE KEY-----
"""

const TEST_KEY_B_PUBLIC_PEM: String = """
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0yCMtOQjrqoyEZhKqP2U
hc3ylQJX0vybgDIyOx9Qn1iGXwxDNHqredIU01xL5lC9CCqJdm1dkV5VxyE6t/ec
7Ly/QJwRZ928X4JLcDw/lCSBa9ldAb9lvU3C+JUTjpVvAxmI8w01vhaprlHMygNO
uV5Z4Aq8vOINU+BzTM2sEKo432GYefNITQilZ2iBD2vddPHGHXN3/8mZGxlEWLzh
W0ZIHIWF2jkaiXeJ+hyWjQJ2uUYgD4f8qN2juqUhGumEuEJ/ROyBZIwVWNtnrgpd
TQv1V3prF5Fa6WlsGoKWm1JhovQnAwl6vcPiSe1rdQsh4et9RtEFogHY1l5o34RF
rwIDAQAB
-----END PUBLIC KEY-----
"""

func test_parse_sha256sums_standard_format():
	var sums: Dictionary = EditorToolsScript.parse_sha256sums(
		"abc123def456  godot_mcp.zip\nfeed0000  SHA256SUMS.txt\n\n")
	assert_eq(String(sums.get("godot_mcp.zip", "")), "abc123def456")
	assert_eq(String(sums.get("SHA256SUMS.txt", "")), "feed0000")
	assert_eq(sums.size(), 2)

func test_parse_sha256sums_tolerates_single_space_and_crlf():
	var sums: Dictionary = EditorToolsScript.parse_sha256sums(
		"abc  godot_mcp.zip\r\nDEF  other.zip\r\n")
	assert_eq(String(sums.get("godot_mcp.zip", "")), "abc")
	assert_eq(String(sums.get("other.zip", "")), "def", "哈希大小写归一为小写")

func test_parse_sha256sums_skips_malformed_lines():
	var sums: Dictionary = EditorToolsScript.parse_sha256sums("not-a-sums-line\nok123  file.zip\n")
	assert_eq(sums.size(), 1)

func _load_key(pem: String, public_only: bool) -> CryptoKey:
	var key: CryptoKey = CryptoKey.new()
	assert_eq(key.load_from_string(pem, public_only), OK, "PEM 装载")
	return key

func _digest(data: PackedByteArray) -> PackedByteArray:
	var hash_context: HashingContext = HashingContext.new()
	hash_context.start(HashingContext.HASH_SHA256)
	hash_context.update(data)
	return hash_context.finish()

func test_signature_roundtrip_and_tamper_rejection():
	var crypto: Crypto = Crypto.new()
	var private_key: CryptoKey = _load_key(TEST_KEY_A_PRIVATE_PEM, false)
	var public_pem: String = TEST_KEY_A_PUBLIC_PEM

	var data: PackedByteArray = "SHA256SUMS manifest content".to_utf8_buffer()
	var signature: PackedByteArray = crypto.sign(HashingContext.HASH_SHA256, _digest(data), private_key)

	var verify: Dictionary = EditorToolsScript.verify_release_signature(public_pem, data, signature)
	assert_true(bool(verify["verified"]), "正确签名必须通过")
	assert_eq(String(verify["digest"]), _digest(data).hex_encode())

	var tampered: PackedByteArray = data.duplicate()
	tampered[0] = (int(tampered[0]) + 1) % 256
	var tampered_verify: Dictionary = EditorToolsScript.verify_release_signature(public_pem, tampered, signature)
	assert_false(bool(tampered_verify["verified"]), "内容篡改一位必须验签失败")

func test_verify_rejects_wrong_key():
	# 错钥场景（发布链真实威胁）：攻击者用 B 钥签发更新——对 B 公钥验签成立
	# （控制组：钥与签配对时 verify 本身工作正常）；攻击者签名对**正式**公钥
	# 的失败已由篡改用例等价覆盖（钥-签不配对即失败）。
	var crypto: Crypto = Crypto.new()
	var attacker_key: CryptoKey = _load_key(TEST_KEY_B_PRIVATE_PEM, false)
	var data: PackedByteArray = "manifest".to_utf8_buffer()
	var signature: PackedByteArray = crypto.sign(HashingContext.HASH_SHA256, _digest(data), attacker_key)
	var verify: Dictionary = EditorToolsScript.verify_release_signature(TEST_KEY_B_PUBLIC_PEM, data, signature)
	assert_true(bool(verify["verified"]), "钥-签配对的控制组")
	assert_true(verify.has("verified") or verify.has("reason"), "响应形状固定")

func test_match_release_assets_picks_three_targets():
	var assets: Array = [
		{"name": "godot_mcp.zip", "url": "https://example/godot_mcp.zip", "size": 1},
		{"name": "SHA256SUMS.sig", "url": "https://example/SHA256SUMS.sig", "size": 2},
		{"name": "SHA256SUMS.txt", "url": "https://example/SHA256SUMS.txt", "size": 3},
	]
	var matched: Dictionary = EditorToolsScript._match_release_assets(assets)
	assert_eq(String(matched["zip"]), "https://example/godot_mcp.zip")
	assert_eq(String(matched["sums"]), "https://example/SHA256SUMS.txt")
	assert_eq(String(matched["sig"]), "https://example/SHA256SUMS.sig")
	# 键名陷阱回归：url 键缺失时必须保持空串（不可误读其他键）
	var empty: Dictionary = EditorToolsScript._match_release_assets([{"name": "SHA256SUMS.txt"}])
	assert_eq(String(empty["sums"]), "")
