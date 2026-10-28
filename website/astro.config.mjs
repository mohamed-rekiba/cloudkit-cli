// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLinksValidator from 'starlight-links-validator';

// https://astro.build/config
export default defineConfig({
	site: 'https://cloudkit-cli.pages.dev',
	integrations: [
		starlight({
			title: 'CloudKit',
			description:
				'One ck command for AWS and Google Cloud: per-terminal sessions, SSM and IAP connections, and service shortcuts.',
			logo: { src: './src/assets/logo-icon.svg' },
			social: [
				{ icon: 'github', label: 'GitHub', href: 'https://github.com/shabayekdes/cloudkit-cli' },
			],
			editLink: {
				baseUrl: 'https://github.com/shabayekdes/cloudkit-cli/edit/main/website/',
			},
			customCss: ['./src/styles/custom.css'],
			lastUpdated: true,
			plugins: [starlightLinksValidator()],
			sidebar: [
				{
					label: 'Start here',
					items: [
						{ label: 'Quick start', slug: 'getting-started' },
						'start/installation',
						'start/aws',
						'start/gcloud',
					],
				},
				{
					label: 'Concepts',
					items: [
						'concepts/how-it-works',
						'sessions',
						'concepts/targeting',
						'concepts/prompt-and-production',
					],
				},
				{
					label: 'Guides',
					items: [
						'guides/connect-ec2',
						'guides/connect-gce',
						'guides/start-stop',
						'guides/ecs',
						'guides/port-forwarding',
						'guides/file-transfer',
						'guides/environments',
						'guides/diagnose',
					],
				},
				{
					label: 'Command reference',
					items: [{ autogenerate: { directory: 'commands' } }],
				},
				{
					label: 'Reference',
					items: [
						'configuration',
						'reference/permissions',
						'reference/limitations',
						'troubleshooting',
					],
				},
				{
					label: 'Project',
					items: ['contributing'],
				},
			],
		}),
	],
});
