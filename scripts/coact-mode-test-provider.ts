// Registers the scripted test model as coact-test/echo for Coact mode tests.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	pi.registerProvider("coact-test", {
		name: "Coact test",
		baseUrl: process.env.COACT_TEST_BASE_URL ?? "http://127.0.0.1:1/v1",
		apiKey: "test",
		api: "openai-completions",
		models: [
			{
				id: "echo",
				name: "Scripted echo",
				reasoning: false,
				input: ["text"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 128000,
				maxTokens: 4096,
			},
		],
	});
}
