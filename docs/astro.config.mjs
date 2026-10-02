// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLinksValidator from 'starlight-links-validator';
import starlightLlmsTxt from 'starlight-llms-txt';

// The sidebar, in reading order. The llms.txt files below follow the same order.
const sidebar = [
	{
		label: 'Getting Started',
		items: ['getting-started/installation', 'getting-started/quick-start'],
	},
	{
		label: 'Guides',
		items: [
			'guides/guarantees',
			'guides/how-it-works',
			'guides/migrating-from-profilestore',
			'guides/importing-from-other-libraries',
			'guides/schema-and-migrations',
			'guides/purchases',
			'guides/messages-and-edits',
			'guides/trades',
			'guides/shared-documents',
			'guides/leaderboards',
			'guides/versions-and-rollback',
			'guides/large-profiles',
			'guides/studio-and-testing',
			'guides/roblox-ts',
			'guides/benchmarks',
			'guides/other-libraries',
		],
	},
	{
		label: 'Reference',
		items: ['reference/store', 'reference/profile', 'reference/config', 'reference/load-failures'],
	},
	'changelog',
];

// The plain-text copies of the site for AI assistants.
const llmsTxt = {
	details: [
		'KeepBlox keeps session-locked player profiles on Roblox DataStore, in the same record format as',
		'ProfileStore, so a game can switch with one require and run mixed servers during a rollout.',
		'Every guarantee is proven by a spec in the repository; take API names from these pages.',
	].join('\n'),
	promote: ['index*', ...sidebar.flatMap((entry) => (typeof entry === 'string' ? [entry] : entry.items))],
	demote: ['guides/benchmarks', 'changelog'],
	exclude: ['guides/benchmarks', 'changelog'],
	minify: { note: false },
	customSelectors: { all: ['h1'] },
};

export default defineConfig({
	vite: {
		build: {
			rolldownOptions: {
				// Astro marks every MDX page with its own "use astro:head-inject" directive, and Vite's
				// bundler warns once per page that it does not know it. Astro reads the directive itself,
				// so only that warning is dropped; every other one still prints.
				onwarn(warning, warn) {
					if (warning.code === 'MODULE_LEVEL_DIRECTIVE' && warning.message.includes('astro:head-inject')) {
						return;
					}
					warn(warning);
				},
			},
		},
	},
	site: 'https://xopoiii.github.io',
	base: '/KeepBlox',
	integrations: [
		starlight({
			title: 'KeepBlox',
			// src/pages/404.astro says why.
			disable404Route: true,
			description: 'Player data for Roblox that loses nothing, fails loudly, and never stutters a frame.',
			logo: { src: './src/assets/logo.png', alt: 'KeepBlox' },
			favicon: '/favicon-32.png',
			head: [
				{ tag: 'link', attrs: { rel: 'icon', type: 'image/png', sizes: '192x192', href: '/KeepBlox/favicon.png' } },
				{ tag: 'link', attrs: { rel: 'apple-touch-icon', href: '/KeepBlox/apple-touch-icon.png' } },
				{ tag: 'meta', attrs: { property: 'og:image', content: 'https://xopoiii.github.io/KeepBlox/og.png' } },
				{ tag: 'meta', attrs: { name: 'twitter:image', content: 'https://xopoiii.github.io/KeepBlox/og.png' } },
			],
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/XopoIII/KeepBlox' }],
			editLink: { baseUrl: 'https://github.com/XopoIII/KeepBlox/edit/main/docs/' },
			lastUpdated: true,
			customCss: ['./src/styles/custom.css'],
			expressiveCode: { themes: ['catppuccin-mocha', 'catppuccin-latte'] },
			plugins: [starlightLinksValidator(), starlightLlmsTxt(llmsTxt)],
			sidebar,
		}),
	],
});
