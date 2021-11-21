; Test constants module

(module constants GOVERNANCE
  "Test constants"
  (defcap GOVERNANCE () true)

  (defconst request-public-key "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
  (defconst request-private-key "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
  (defconst nonce "AQIDBAUGBwgJEBES")

  (defconst share1-plaintext "dGhpc3N0cmluZ25lZWRzdG9iZWV4YWN0bHl0aGVzYW1lbGVuZ3RoYXNjaWRhbmRoYXNo")
  (defconst share1-ciphertext "PDAURXAhmxvzyfxqrFRNaI2BZje6AXOD1HLYbWff1XE1WLiRUm_VstTJ2upTDXBq2bXf")
  (defconst share1-mac "rjoNds9O9MYkAFyZdBXmng")

  (defconst share2-plaintext "AAAAABoHExsPCQoKCBcHBgYMAtOIPPROQDZ-oa7Aq_AOtJ_3QhSmH-84i7YtBJiLXiZN")
  (defconst share2-ciphertext "SFh9NhlS-mmSp5gFwSc5GuTvAYFKXOS5-D3SpKxsH-xegEIIdw8bzEiSODgfZ4yJ5uD6")
  (defconst share2-mac "43kHKzaJ3OfRCRBsEzP7Zw")

  (defconst share1-hash "mUzoqs8RrXRYI58pTLkmNH8Opc-JSGwl4IeLqr3AXws")
  (defconst share2-hash "F77o73aUvhn0rFGdRxXgtpH80kfHNzxuBEtU8tZ1ffE")

  (defconst sharing-node-1 "sharing-node-1")
  (defconst sharing-node-2 "sharing-node-2")
  (defconst sharing-node-3 "sharing-node-3")
  (defconst sharing-node-nonexistent "sharing-node-nonexistent")
)
