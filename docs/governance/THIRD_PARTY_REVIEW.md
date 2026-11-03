# Third-party content review

AgentShield intentionally ships no third-party skills. Organizations that add
local skills beside an AgentShield deployment must verify and record for every
component:

- original source and immutable revision;
- redistribution permission and license text;
- copyright and notice obligations;
- integrity hash and review date;
- removal or update procedure when a security issue is reported.

Do not install a skill directly from a URL during an agent session. A skill is
instruction content the agent may obey; treat it as a supply-chain artifact.
Keep locally approved skills outside this repository unless their provenance,
license, and redistribution terms have been verified for an intentional public
release.
