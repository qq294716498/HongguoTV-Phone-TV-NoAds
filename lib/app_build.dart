const allSourcesEnabled = bool.fromEnvironment('ALL_SOURCES');
const isolatedTestBuild = bool.fromEnvironment('ISOLATED_TEST');
const publicUpdatesEnabled = allSourcesEnabled && !isolatedTestBuild;
const appName = '红果TV';
const appSlug = 'hongguotv';
