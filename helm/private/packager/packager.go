package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path"
	"regexp"
	"strings"

	yaml "gopkg.in/yaml.v3"
)

type ImageManifest struct {
	Label      string
	Registry   string
	Repository string
	Digest     string
}
type ImagesManifest []ImageManifest

type (
	DataManifest map[string]string
	DepsManifest []string
)

type HelmResultMetadata struct {
	Name    string `json:"name" yaml:"name"`
	Version string `json:"version" yaml:"version"`
}

type HelmChart struct {
	ApiVersion  string `yaml:"apiVersion"`
	Name        string `yaml:"name"`
	Description string `yaml:"description"`
	Type        string `yaml:"type"`
	Version     string `yaml:"version"`
	AppVersion  string `yaml:"appVersion"`
}

type Arguments struct {
	DataManifest       string
	Chart              string
	Values             string
	DepsManifest       string
	Helm               string
	Output             string
	MetadataOutput     string
	ImageManifest      string
	StableStatusFile   string
	VolatileStatusFile string
	WorkspaceName      string
}

func ParseArgs() *Arguments {
	var args Arguments

	flag.StringVar(&args.DataManifest, "data_manifest", "", "A helm file containing a list of all helm data files")
	flag.StringVar(&args.Chart, "chart", "", "The helm `chart.yaml` file")
	flag.StringVar(&args.Values, "values", "", "The helm `values.yaml` file.")
	flag.StringVar(&args.DepsManifest, "deps_manifest", "", "A file containing a list of all helm dependency (`charts/*.tgz`) files")
	flag.StringVar(&args.Helm, "helm", "", "The path to a helm executable")
	flag.StringVar(&args.Output, "output", "", "The path to the Bazel `HelmPackage` action output")
	flag.StringVar(&args.MetadataOutput, "metadata_output", "", "The path to the Bazel `HelmPackage` action metadata output")
	flag.StringVar(&args.ImageManifest, "image_manifest", "", "Information about Bazel produced container oci images used by the helm chart")
	flag.StringVar(&args.StableStatusFile, "stable_status_file", "", "The stable status file (`ctx.info_file`)")
	flag.StringVar(&args.VolatileStatusFile, "volatile_status_file", "", "The stable status file (`ctx.version_file`)")
	flag.StringVar(&args.WorkspaceName, "workspace_name", "", "The name of the current Bazel workspace")
	flag.Parse()

	return &args
}

func LoadStamps(volatile string, stable string) map[string]string {
	stamps := make(map[string]string)

	stampFiles := []string{volatile, stable}
	for _, stampFile := range stampFiles {

		// The files may not be defined
		if len(stampFile) == 0 {
			continue
		}

		f, err := os.Open(stampFile)
		if err != nil {
			log.Fatalf("error open %s: %s", stampFile, err)
		}
		defer f.Close()

		scanner := bufio.NewScanner(f)
		scanner.Split(bufio.ScanLines)
		for scanner.Scan() {
			line := scanner.Text()
			split := strings.SplitN(line, " ", 2)
			if len(split) < 2 {
				continue
			}
			key, val := split[0], split[1]
			stamps[key] = val
		}
	}

	return stamps
}

type readManifest func([]byte) ImageManifest

func LoadImageStamps(imageManifest string, workspaceName string, applyReadManifest readManifest) map[string]string {
	images := make(map[string]string)

	if len(imageManifest) == 0 {
		return images
	}

	content, err := os.ReadFile(imageManifest)
	if err != nil {
		log.Fatal("error reading ", imageManifest, err)
	}
	var paths []string
	_ = json.Unmarshal(content, &paths)
	for _, path := range paths {
		content, err := os.ReadFile(path)
		if err != nil {
			log.Fatalf("Error during ReadFile %s: %s", path, err)
		}
		manifest := applyReadManifest(content)
		registryUrl := fmt.Sprintf("%s/%s@%s", manifest.Registry, manifest.Repository, manifest.Digest)
		images[manifest.Label] = registryUrl

		// There are many ways to represent the same target from a label. Here we
		// attempt to handle a variety of cases.
		if strings.HasPrefix(manifest.Label, "@") {
			if strings.HasPrefix(manifest.Label, "@//") {
				absLabel := fmt.Sprintf("@%s%s", workspaceName, strings.Replace(manifest.Label, "@//", "//", 1))
				images[absLabel] = registryUrl
				localLabel := fmt.Sprintf("@%s%s", workspaceName, strings.Replace(manifest.Label, "@//", "//", 1))
				images[localLabel] = registryUrl
				absRelativeLabel := fmt.Sprintf("@@%s", strings.Replace(manifest.Label, "@//", "//", 1))
				images[absRelativeLabel] = registryUrl
			}
			if strings.HasPrefix(manifest.Label, "@@//") {
				absLabel := fmt.Sprintf("@@%s%s", workspaceName, strings.Replace(manifest.Label, "@@//", "//", 1))
				images[absLabel] = registryUrl
				localLabel := fmt.Sprintf("@%s%s", workspaceName, strings.Replace(manifest.Label, "@@//", "//", 1))
				images[localLabel] = registryUrl
				relativeLabel := fmt.Sprintf("@%s", strings.Replace(manifest.Label, "@@//", "//", 1))
				images[relativeLabel] = registryUrl
			}

			// Comes from bzlmod
			if strings.HasPrefix(manifest.Label, "@@_main//") {
				absLabel := fmt.Sprintf("@@%s%s", workspaceName, strings.Replace(manifest.Label, "@@_main//", "//", 1))
				images[absLabel] = registryUrl
				localLabel := fmt.Sprintf("@%s%s", workspaceName, strings.Replace(manifest.Label, "@@_main//", "//", 1))
				images[localLabel] = registryUrl
				relativeLabel := fmt.Sprintf("@%s", strings.Replace(manifest.Label, "@@_main//", "//", 1))
				images[relativeLabel] = registryUrl
			}
		}
	}

	log.Println(images)

	return images
}

func readOciImageManifest(content []byte) ImageManifest {
	imageManifest := ImageManifest{}
	type LocalManifest = struct {
		Label string
		Paths []string
	}
	localManifest := LocalManifest{}
	manifestDir := ""
	yqPath := ""
	_ = json.Unmarshal(content, &localManifest)
	imageManifest.Label = localManifest.Label
	for _, path := range localManifest.Paths {
		file, _ := os.Open(path)
		stat, _ := file.Stat()
		if strings.HasSuffix(stat.Name(), ".sh") {
			scanner := bufio.NewScanner(file)
			for scanner.Scan() {
				text := scanner.Text()
				if strings.HasPrefix(text, "readonly FIXED_ARGS") {
					image := strings.SplitN(strings.Replace(strings.Replace(strings.Split(text, " ")[2], "\"", "", -1), ")", "", -1), "/", 2)
					imageManifest.Registry = image[0]
					imageManifest.Repository = image[1]
				}
			}
		}
		if stat.IsDir() {
			manifestDir = path
		}
		if strings.HasSuffix(stat.Name(), "yq") {
			yqPath = path
		}
		digest, _ := exec.Command(yqPath, ".manifests[0].digest", manifestDir+"/index.json").Output()
		imageManifest.Digest = strings.Replace(string(digest), "\n", "", -1)
		file.Close()
	}
	return imageManifest
}

func ApplyStamping(content string, stamps map[string]string) string {
	sb := &strings.Builder{}
	_, err := ExecuteFunc(content, "{", "}", sb, func(w io.Writer, tag string) (int, error) {
		if val, ok := stamps[tag]; ok {
			return io.WriteString(w, val)
		}
		return fmt.Fprintf(w, "{%s}", tag)
	})
	if err != nil {
		log.Fatal(err)
	}

	return sb.String()
}

func SanitizeChartContent(content string) string {
	re := regexp.MustCompile(`.*{.+}.*`)

	var chart HelmChart
	err := yaml.Unmarshal([]byte(content), &chart)
	if err != nil {
		log.Fatal(err)
	}

	// TODO: This should probably happen for all values
	m := re.FindAllString(chart.Version, 1)
	if len(m) != 0 {
		replacement := strings.NewReplacer("{", "", "}", "", "_", "-").Replace(m[0])
		content = strings.ReplaceAll(content, m[0], replacement)
	}

	return content
}

func GetChartName(content string) string {
	var chart HelmChart
	err := yaml.Unmarshal([]byte(content), &chart)
	if err != nil {
		log.Fatal(err)
	}

	return chart.Name
}

func CopyFile(src string, dest string) {
	srcFile, err := os.Open(src)
	if err != nil {
		log.Fatal(err)
	}
	defer srcFile.Close()

	if err := os.MkdirAll(path.Dir(dest), 0o755); err != nil {
		log.Fatal(err)
	}

	destFile, err := os.Create(dest)
	if err != nil {
		log.Fatal(err)
	}
	defer destFile.Close()

	_, err = io.Copy(destFile, srcFile)
	if err != nil {
		log.Fatal(err)
	}
}

func InstallHelmContent(workingDir string, stampedChartContent string, stampedValuesContent string, templatesManifest string, depsManifest string) {
	err := os.MkdirAll(workingDir, 0o755)
	if err != nil {
		log.Fatal(err)
	}

	chartYAML := path.Join(workingDir, "Chart.yaml")
	if err := os.WriteFile(chartYAML, []byte(stampedChartContent), 0o644); err != nil {
		log.Fatal(err)
	}

	valuesYAML := path.Join(workingDir, "values.yaml")
	if err := os.WriteFile(valuesYAML, []byte(stampedValuesContent), 0o644); err != nil {
		log.Fatal(err)
	}

	manifestContent, err := os.ReadFile(templatesManifest)
	if err != nil {
		log.Fatal(err)
	}

	var data DataManifest
	err = json.Unmarshal(manifestContent, &data)
	if err != nil {
		log.Fatal(err)
	}

	// Copy all templates
	for fullPath, shortPath := range data {
		CopyFile(fullPath, path.Join(workingDir, shortPath))
	}

	// Copy over any dependency chart files
	if len(depsManifest) > 0 {
		manifestContent, err := os.ReadFile(depsManifest)
		if err != nil {
			log.Fatal(err)
		}

		var deps DepsManifest
		err = json.Unmarshal(manifestContent, &deps)
		if err != nil {
			log.Fatal(err)
		}

		for _, dep := range deps {
			CopyFile(dep, path.Join(workingDir, "charts", path.Base(dep)))
		}
	}
}

func FindGeneratedPackage(logging string) (string, error) {
	if strings.Contains(logging, ":") {
		// This line assumes the logging from helm will be a single line of
		// text which starts with `Successfully packaged chart and saved it to:`
		split := strings.SplitN(logging, ":", 2)
		pkg := strings.TrimSpace(split[1])
		if _, err := os.Stat(pkg); err == nil {
			return pkg, nil
		}
	}

	return "", errors.New("failed to find package")
}

func WriteResultsMetadata(packageBase string, output string) {
	re := regexp.MustCompile(`(.+)-([\d][\d\w\-\.]+)\.tgz`)
	match := re.FindAllStringSubmatch(packageBase, 2)

	if len(match) == 0 {
		log.Fatalf("Unable to parse file name: %s", packageBase)
	}

	metadata := HelmResultMetadata{
		Name:    match[0][1],
		Version: match[0][2],
	}

	outputFile, err := os.Create(output)
	if err != nil {
		log.Fatal(err)
	}
	defer outputFile.Close()

	enc := json.NewEncoder(outputFile)
	enc.SetIndent("", "    ")
	if err := enc.Encode(metadata); err != nil {
		log.Fatal(err)
	}
}

func main() {
	args := ParseArgs()

	log.SetFlags(log.LstdFlags | log.Lshortfile)

	cwd, err := os.Getwd()
	if err != nil {
		log.Fatal(err)
	}

	dir := path.Join(cwd, ".rules_helm_pkg_dir")

	chartContent, err := os.ReadFile(args.Chart)
	if err != nil {
		log.Fatal(err)
	}

	valuesContent, err := os.ReadFile(args.Values)
	if err != nil {
		log.Fatal(err)
	}

	// Collect all stamp values
	stamps := LoadStamps(args.VolatileStatusFile, args.StableStatusFile)
	imageStamps := LoadImageStamps(args.ImageManifest, args.WorkspaceName, readOciImageManifest)

	// Merge stamps
	for k, v := range imageStamps {
		stamps[k] = v
	}

	// Stamp any templates out of top level helm sources
	StampedValuesContent := ApplyStamping(string(valuesContent), stamps)
	StampedChartContent := SanitizeChartContent(ApplyStamping(string(chartContent), stamps))

	// Create a directory in which to run helm package
	chartName := GetChartName(StampedChartContent)
	tmpPath := path.Join(dir, chartName)
	InstallHelmContent(tmpPath, StampedChartContent, StampedValuesContent, args.DataManifest, args.DepsManifest)

	// Build the helm package
	command := exec.Command(path.Join(cwd, args.Helm), "package", ".")
	command.Dir = tmpPath
	out, err := command.CombinedOutput()
	if err != nil {
		log.Fatalf("Error running helm package: %s, output: %s", err, string(out))
	}

	// Locate the package file
	pkg, err := FindGeneratedPackage(string(out))
	if err != nil {
		os.Stderr.WriteString(string(out))
		log.Fatal(err)
	}

	// Write output metadata file to satisfy the Bazel output
	CopyFile(pkg, args.Output)

	// Write output metadata to retain information about the helm package
	WriteResultsMetadata(path.Base(pkg), args.MetadataOutput)
}
